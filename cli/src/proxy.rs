//! The bridge itself: raw stdin ↔ remote PTY, with a leader-key interceptor,
//! OSC 52 clipboard capture on output, terminal resize sync, and Smart Paste.

use anyhow::{Context, Result};
use russh::ChannelMsg;
use std::io::Write;
use std::time::Duration;
use tokio::sync::mpsc;

use crate::clipboard::{self, ClipContent};
use crate::config::{Osc52Policy, PasteIntercept, Resolved, StatusMode};
use crate::cwd::Osc7Tracker;
use crate::osc52::Osc52Scanner;
use crate::paste::{PasteEvent, PasteScanner};
use crate::session::{self, Ssh};
use crate::term;
use crate::upload;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::Mutex;

const PREVIEW_CHARS: usize = 40;

/// Session-wide status routing, consulted by `status()`. Kept as process
/// globals so every handler can emit without threading UI state through its
/// signature (one session per process).
static STATUS_MODE: AtomicU8 = AtomicU8::new(0);
/// Whether a remote full-screen app is active (bracketed paste enabled). Inline
/// writes would corrupt its rendering, so in `auto` we notify instead.
static APP_ACTIVE: AtomicBool = AtomicBool::new(false);
/// Last cwd reported by the remote shell via OSC 7 — used to scope uploads.
static CURRENT_CWD: Mutex<Option<String>> = Mutex::new(None);

fn current_cwd() -> Option<String> {
    CURRENT_CWD.lock().unwrap().clone()
}

enum InputState {
    Normal,
    /// leader pressed, waiting for the command key
    Pending(std::time::Instant),
    /// a clipboard action is held for y/n confirmation ("ask" policies);
    /// input bytes are consumed by the prompt, not forwarded
    Confirm,
}

enum PendingConfirm {
    /// remote OSC 52 write into the local clipboard
    Write(Vec<u8>),
    /// a native paste of local file paths, awaiting upload approval
    Paste { paths: Vec<PathBuf>, raw: Vec<u8> },
}

pub async fn run(cfg: Resolved) -> Result<()> {
    eprintln!(
        "[devbox] connecting to {}@{}:{} …",
        cfg.user, cfg.host, cfg.port
    );
    let mut ssh = session::connect(&cfg).await?;
    set_status_mode(cfg.status);
    eprintln!("[devbox] connected · inbox {} · leader Ctrl+{} (then V = smart paste, Q = disconnect, ? = help)",
        ssh.inbox, leader_letter(cfg.leader));

    let _raw = term::RawGuard::enable()?;

    // stdin: blocking reader thread → channel of raw byte chunks
    let (stdin_tx, mut stdin_rx) = mpsc::channel::<Vec<u8>>(64);
    std::thread::spawn(move || {
        use std::io::Read;
        let mut stdin = std::io::stdin().lock();
        let mut buf = [0u8; 8192];
        loop {
            match stdin.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    if stdin_tx.blocking_send(buf[..n].to_vec()).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    let (resize_tx, mut resize_rx) = mpsc::channel::<(u16, u16)>(8);
    spawn_resize_watcher(resize_tx);

    let mut stdout = std::io::stdout();
    let mut scanner = Osc52Scanner::new();
    let mut paste_scanner = PasteScanner::new();
    let mut cwd_tracker = Osc7Tracker::new();
    let mut state = InputState::Normal;
    // clipboard actions queued behind the "ask" confirmation prompt
    let mut pending: std::collections::VecDeque<PendingConfirm> = std::collections::VecDeque::new();

    loop {
        let leader_deadline = match state {
            InputState::Pending(at) => {
                let elapsed = at.elapsed();
                if elapsed >= cfg.leader_timeout {
                    Duration::ZERO
                } else {
                    cfg.leader_timeout - elapsed
                }
            }
            InputState::Normal | InputState::Confirm => Duration::from_secs(3600),
        };

        tokio::select! {
            // ── local input ──
            chunk = stdin_rx.recv() => {
                let Some(chunk) = chunk else { break };
                for event in paste_scanner.feed(&chunk) {
                let bytes = match event {
                    PasteEvent::Paste(body) => {
                        handle_paste(&mut ssh, &cfg, body, &mut pending, &mut state, &mut stdout).await;
                        continue;
                    }
                    PasteEvent::Pass(b) => b,
                };
                let mut pass = Vec::with_capacity(bytes.len());
                for b in bytes {
                    match state {
                        InputState::Normal => {
                            if b == cfg.leader {
                                state = InputState::Pending(std::time::Instant::now());
                            } else {
                                pass.push(b);
                            }
                        }
                        InputState::Pending(_) => {
                            state = InputState::Normal;
                            match b {
                                b'v' | b'V' => {
                                    if !pass.is_empty() { ssh.shell.data(&pass[..]).await.ok(); pass.clear(); }
                                    smart_paste(&mut ssh, &cfg, &mut stdout, scanner.bracketed_paste).await;
                                }
                                b'q' | b'Q' => {
                                    status(&mut stdout, "disconnecting…");
                                    return finish(ssh).await;
                                }
                                b'?' | b'h' => help(&mut stdout, cfg.leader),
                                _ if b == cfg.leader => pass.push(b), // leader twice → literal
                                other => { pass.push(cfg.leader); pass.push(other); }
                            }
                        }
                        InputState::Confirm => {
                            let allowed = b == b'y' || b == b'Y';
                            if let Some(action) = pending.pop_front() {
                                match action {
                                    PendingConfirm::Write(payload) => {
                                        if allowed {
                                            apply_clip(&mut stdout, &payload, false);
                                        } else {
                                            status(&mut stdout, "remote clipboard write denied");
                                        }
                                    }
                                    PendingConfirm::Paste { paths, raw } => {
                                        if allowed {
                                            upload_and_type(&mut ssh, &cfg, &paths, &mut stdout).await;
                                        } else {
                                            send_framed(&mut ssh, &raw).await;
                                        }
                                    }
                                }
                            }
                            state = match pending.front() {
                                Some(next) => {
                                    prompt_confirm(&mut stdout, next);
                                    InputState::Confirm
                                }
                                None => InputState::Normal,
                            };
                        }
                    }
                }
                if !pass.is_empty() {
                    ssh.shell.data(&pass[..]).await.context("send input")?;
                }
                }
            }

            // ── leader timeout: user meant the literal control byte ──
            _ = tokio::time::sleep(leader_deadline), if matches!(state, InputState::Pending(_)) => {
                state = InputState::Normal;
                ssh.shell.data(&[cfg.leader][..]).await.ok();
            }

            // ── remote output ──
            msg = ssh.shell.wait() => {
                match msg {
                    Some(ChannelMsg::Data { data }) => {
                        let scanned = scanner.feed(&data);
                        // track whether a full-screen remote app owns the screen
                        APP_ACTIVE.store(scanner.bracketed_paste, Ordering::Relaxed);
                        // track the shell's cwd (OSC 7) to scope uploads to the project
                        if let Some(dir) = cwd_tracker.feed(&data) {
                            *CURRENT_CWD.lock().unwrap() = Some(dir);
                        }
                        for payload in scanned.clipboard {
                            handle_osc52_write(&cfg, payload, &mut pending, &mut state, &mut stdout);
                        }
                        stdout.write_all(&scanned.output)?;
                        stdout.flush()?;
                    }
                    Some(ChannelMsg::ExtendedData { data, .. }) => {
                        stdout.write_all(&data)?;
                        stdout.flush()?;
                    }
                    Some(ChannelMsg::ExitStatus { .. }) | Some(ChannelMsg::Close) | None => {
                        status(&mut stdout, "remote session closed");
                        return finish(ssh).await;
                    }
                    _ => {}
                }
            }

            // ── resize sync ──
            sz = resize_rx.recv() => {
                if let Some((cols, rows)) = sz {
                    ssh.shell.window_change(cols as u32, rows as u32, 0, 0).await.ok();
                }
            }
        }
    }

    finish(ssh).await
}

async fn finish(ssh: Ssh) -> Result<()> {
    ssh.shell.eof().await.ok();
    ssh.handle
        .disconnect(russh::Disconnect::ByApplication, "devbox disconnect", "en")
        .await
        .ok();
    Ok(())
}

/// A native paste (⌘V / drag-and-drop) that the stdin scanner pulled out.
/// If it is entirely local file paths, upload them and type the remote paths;
/// otherwise re-frame and forward the paste byte-exact.
async fn handle_paste(
    ssh: &mut Ssh,
    cfg: &Resolved,
    body: Vec<u8>,
    pending: &mut std::collections::VecDeque<PendingConfirm>,
    state: &mut InputState,
    out: &mut impl Write,
) {
    // only intercept from a clean input state; never mid-leader / mid-prompt
    let interceptable =
        cfg.paste_intercept != PasteIntercept::Off && matches!(state, InputState::Normal);
    if !interceptable {
        return send_framed(ssh, &body).await;
    }
    let paths = match std::str::from_utf8(&body).map(|s| clipboard::classify_text(s.to_string())) {
        Ok(ClipContent::Files(p)) => p,
        _ => return send_framed(ssh, &body).await, // text / dir / binary → verbatim
    };

    match cfg.paste_intercept {
        PasteIntercept::Off => unreachable!("checked above"),
        PasteIntercept::Auto => upload_and_type(ssh, cfg, &paths, out).await,
        PasteIntercept::Ask => {
            let n = paths.len();
            pending.push_back(PendingConfirm::Paste { paths, raw: body });
            if !matches!(state, InputState::Confirm) {
                status_prompt(
                    out,
                    &format!("paste is {n} local file path(s) — upload? (y/n)"),
                );
                *state = InputState::Confirm;
            }
        }
    }
}

async fn upload_and_type(ssh: &mut Ssh, cfg: &Resolved, paths: &[PathBuf], out: &mut impl Write) {
    let dir = upload::upload_dir(ssh, cfg, current_cwd().as_deref()).await;
    let mut remotes = Vec::new();
    for p in paths {
        match upload::upload_file(&ssh.sftp, &dir, p).await {
            Ok(r) => remotes.push(r),
            Err(e) => status(out, &format!("upload {} failed: {e}", p.display())),
        }
    }
    if !remotes.is_empty() {
        status(out, &format!("uploaded → {}", remotes.join(", ")));
        type_paths(ssh, cfg, &remotes).await;
    }
}

/// Forward a paste body to the remote wrapped in the paste markers it arrived in.
async fn send_framed(ssh: &mut Ssh, body: &[u8]) {
    let mut framed = Vec::with_capacity(body.len() + 12);
    framed.extend_from_slice(b"\x1b[200~");
    framed.extend_from_slice(body);
    framed.extend_from_slice(b"\x1b[201~");
    ssh.shell.data(&framed[..]).await.ok();
}

/// Apply the per-host OSC 52 policy to one remote clipboard write.
fn handle_osc52_write(
    cfg: &Resolved,
    payload: Vec<u8>,
    pending: &mut std::collections::VecDeque<PendingConfirm>,
    state: &mut InputState,
    out: &mut impl Write,
) {
    if payload.len() > cfg.osc52_max_bytes {
        status(
            out,
            &format!(
                "ignored remote clipboard write: {} bytes > osc52_max_bytes ({})",
                payload.len(),
                cfg.osc52_max_bytes
            ),
        );
        return;
    }
    match cfg.osc52 {
        Osc52Policy::Allow => apply_clip(out, &payload, false),
        Osc52Policy::Notify => apply_clip(out, &payload, true),
        Osc52Policy::Deny => status(
            out,
            &format!(
                "blocked remote clipboard write ({} bytes) — osc52 = deny",
                payload.len()
            ),
        ),
        Osc52Policy::Ask => {
            pending.push_back(PendingConfirm::Write(payload));
            if !matches!(state, InputState::Confirm) {
                prompt_confirm(out, pending.front().expect("just pushed"));
                *state = InputState::Confirm;
            }
        }
    }
}

fn apply_clip(out: &mut impl Write, payload: &[u8], with_preview: bool) {
    match clipboard::write_text(payload) {
        Ok(()) => {
            if with_preview {
                status(
                    out,
                    &format!(
                        "copied {} bytes from remote: “{}”{}",
                        payload.len(),
                        preview(payload),
                        newline_warning(payload)
                    ),
                );
            } else {
                status(out, &format!("copied {} bytes from remote", payload.len()));
            }
        }
        Err(e) => status(out, &format!("clipboard error: {e}")),
    }
}

fn prompt_confirm(out: &mut impl Write, action: &PendingConfirm) {
    match action {
        PendingConfirm::Write(payload) => status_prompt(
            out,
            &format!(
                "remote wants to write {} bytes to your clipboard: “{}”{} — allow? (y/n)",
                payload.len(),
                preview(payload),
                newline_warning(payload)
            ),
        ),
        PendingConfirm::Paste { paths, .. } => status_prompt(
            out,
            &format!(
                "paste is {} local file path(s) — upload? (y/n)",
                paths.len()
            ),
        ),
    }
}

/// Short, control-character-free excerpt: the preview itself must not become
/// an escape-injection vector.
fn preview(payload: &[u8]) -> String {
    let text = String::from_utf8_lossy(payload);
    let mut p: String = text
        .chars()
        .map(|c| if c.is_control() { '·' } else { c })
        .take(PREVIEW_CHARS)
        .collect();
    if text.chars().count() > PREVIEW_CHARS {
        p.push('…');
    }
    p
}

/// A trailing/embedded newline makes a poisoned payload execute on paste
/// before the user can look at it — call it out loudly.
fn newline_warning(payload: &[u8]) -> &'static str {
    if payload.contains(&b'\n') || payload.contains(&b'\r') {
        " ⚠ contains newline (may execute on paste)"
    } else {
        ""
    }
}

fn spawn_resize_watcher(tx: mpsc::Sender<(u16, u16)>) {
    #[cfg(unix)]
    tokio::spawn(async move {
        use tokio::signal::unix::{signal, SignalKind};
        let Ok(mut winch) = signal(SignalKind::window_change()) else {
            return;
        };
        while winch.recv().await.is_some() {
            let _ = tx.send(term::size()).await;
        }
    });
    #[cfg(not(unix))]
    tokio::spawn(async move {
        let mut last = term::size();
        loop {
            tokio::time::sleep(Duration::from_millis(500)).await;
            let now = term::size();
            if now != last {
                last = now;
                if tx.send(now).await.is_err() {
                    break;
                }
            }
        }
    });
}

/// Smart Paste: one shortcut for whatever is in the local clipboard.
async fn smart_paste(ssh: &mut Ssh, cfg: &Resolved, out: &mut impl Write, bracketed: bool) {
    let content = match tokio::task::block_in_place(clipboard::read) {
        Ok(c) => c,
        Err(e) => return status(out, &format!("clipboard error: {e}")),
    };

    match content {
        ClipContent::Empty => status(out, "clipboard is empty"),

        // plain text → behaves like a native paste; markers only when the remote app
        // actually enabled bracketed paste mode (CSI ?2004h), otherwise raw bytes
        ClipContent::Text(t) => {
            let bytes = if bracketed {
                let mut framed = Vec::with_capacity(t.len() + 12);
                framed.extend_from_slice(b"\x1b[200~");
                framed.extend_from_slice(t.as_bytes());
                framed.extend_from_slice(b"\x1b[201~");
                framed
            } else {
                t.into_bytes()
            };
            ssh.shell.data(&bytes[..]).await.ok();
        }

        ClipContent::Png(bytes) => {
            let dir = upload::upload_dir(ssh, cfg, current_cwd().as_deref()).await;
            let name = upload::timestamp_name("clipboard", "png");
            match upload::upload_bytes(&ssh.sftp, &dir, &name, &bytes).await {
                Ok(remote) => {
                    status(out, &format!("uploaded clipboard image → {remote}"));
                    type_paths(ssh, cfg, &[remote]).await;
                }
                Err(e) => status(out, &format!("upload failed: {e}")),
            }
        }

        ClipContent::Files(paths) => upload_and_type(ssh, cfg, &paths, out).await,

        ClipContent::Dir(p) => {
            status(
                out,
                &format!("directory upload not supported yet: {}", p.display()),
            );
        }
    }
}

async fn type_paths(ssh: &mut Ssh, cfg: &Resolved, remotes: &[String]) {
    let joined = remotes
        .iter()
        .map(|r| upload::shell_quote(r))
        .collect::<Vec<_>>()
        .join(" ");
    let text = cfg.paste_template.replace("{path}", &joined);
    ssh.shell.data(text.as_bytes()).await.ok();
}

fn set_status_mode(m: StatusMode) {
    let v = match m {
        StatusMode::Auto => 0,
        StatusMode::Inline => 1,
        StatusMode::Notify => 2,
        StatusMode::Quiet => 3,
    };
    STATUS_MODE.store(v, Ordering::Relaxed);
}

/// True when status should go to an OSC 9 desktop notification rather than an
/// inline line. `force` (for y/n prompts) keeps a message visible even in quiet
/// mode — a prompt the user can't see is worse than a stray line.
fn route_notify(force: bool) -> Option<bool> {
    match STATUS_MODE.load(Ordering::Relaxed) {
        1 => Some(false),                                         // inline
        2 => Some(true),                                          // notify
        3 => force.then_some(APP_ACTIVE.load(Ordering::Relaxed)), // quiet: only prompts
        _ => Some(APP_ACTIVE.load(Ordering::Relaxed)),            // auto
    }
}

fn status(out: &mut impl Write, msg: &str) {
    emit(out, msg, false);
}

/// Like `status`, but for y/n prompts: never fully suppressed.
fn status_prompt(out: &mut impl Write, msg: &str) {
    emit(out, msg, true);
}

fn emit(out: &mut impl Write, msg: &str, force_prompt: bool) {
    let Some(notify) = route_notify(force_prompt) else {
        return;
    };
    if notify {
        // OSC 9 desktop notification — does not touch the screen the remote TUI owns
        let _ = write!(out, "\x1b]9;devbox: {msg}\x07");
    } else {
        // dim one-liner; \r\n because the terminal is in raw mode
        let _ = write!(out, "\r\n\x1b[2m[devbox] {msg}\x1b[0m\r\n");
    }
    let _ = out.flush();
}

fn help(out: &mut impl Write, leader: u8) {
    let l = leader_letter(leader);
    status(
        out,
        &format!("Ctrl+{l} V smart paste · Ctrl+{l} Q disconnect · Ctrl+{l} Ctrl+{l} literal · Ctrl+{l} ? help"),
    );
}

fn leader_letter(leader: u8) -> char {
    (b'A' + leader.saturating_sub(1)) as char
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_routing() {
        // the only test touching these process globals, so no cross-test race
        for (mode, app, want_msg, want_prompt) in [
            (StatusMode::Auto, false, Some(false), Some(false)),
            (StatusMode::Auto, true, Some(true), Some(true)), // TUI active → notify
            (StatusMode::Inline, true, Some(false), Some(false)),
            (StatusMode::Notify, false, Some(true), Some(true)),
            (StatusMode::Quiet, true, None, Some(true)), // messages muted, prompts kept
            (StatusMode::Quiet, false, None, Some(false)), // prompt still visible, inline
        ] {
            set_status_mode(mode);
            APP_ACTIVE.store(app, Ordering::Relaxed);
            assert_eq!(route_notify(false), want_msg, "{mode:?} app={app} msg");
            assert_eq!(route_notify(true), want_prompt, "{mode:?} app={app} prompt");
        }
        set_status_mode(StatusMode::Auto);
        APP_ACTIVE.store(false, Ordering::Relaxed);
    }

    #[test]
    fn preview_strips_control_chars() {
        let p = preview(b"curl x\x1b[31m | sh\n");
        assert!(!p.contains('\x1b'), "ESC must not leak into the preview");
        assert!(!p.contains('\n'));
        assert_eq!(p, "curl x·[31m | sh·");
    }

    #[test]
    fn preview_truncates() {
        let long = "a".repeat(100);
        let p = preview(long.as_bytes());
        assert_eq!(p.chars().count(), PREVIEW_CHARS + 1);
        assert!(p.ends_with('…'));
    }

    #[test]
    fn newline_warning_fires() {
        assert!(newline_warning(b"plain text").is_empty());
        assert!(!newline_warning(b"cmd\n").is_empty());
        assert!(!newline_warning(b"cmd\r").is_empty());
    }
}
