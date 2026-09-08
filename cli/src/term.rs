//! Raw-mode guard: the local terminal becomes a dumb pipe; restore on any exit path.

use anyhow::Result;
use std::io::Write;

/// DEC private modes a remote full-screen app (tmux/vim) may have switched on in
/// *our* terminal: mouse tracking (normal/button/any-motion, UTF-8/SGR/urxvt
/// encodings), focus reporting, bracketed paste, and the alternate screen. If we
/// exit without turning them back off, the local shell is left echoing raw mouse
/// and focus escape sequences on every pointer move. Mirror what a normal
/// SSH/tmux detach emits. Show the cursor too, in case a TUI hid it.
pub const RESTORE: &[u8] = b"\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1004l\x1b[?1005l\x1b[?1006l\x1b[?1015l\x1b[?2004l\x1b[?25h\x1b[?1049l";

/// Restore terminal to canonical (cooked) mode, disable mouse tracking & focus events,
/// restore normal screen buffer, and ensure cursor is visible.
pub fn restore() {
    let mut out = std::io::stdout().lock();
    let _ = out.write_all(RESTORE);
    let _ = out.flush();
    crossterm::terminal::disable_raw_mode().ok();
}

#[cfg(unix)]
pub fn install_signal_handlers() {
    use std::sync::atomic::{AtomicBool, Ordering};
    static INSTALLED: AtomicBool = AtomicBool::new(false);
    if INSTALLED.swap(true, Ordering::SeqCst) {
        return;
    }

    // Set panic hook so panics don't leave the terminal in a broken state
    let prev_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        restore();
        prev_hook(info);
    }));

    tokio::spawn(async {
        use tokio::signal::unix::{signal, SignalKind};
        let Ok(mut sigint) = signal(SignalKind::interrupt()) else {
            return;
        };
        let Ok(mut sigterm) = signal(SignalKind::terminate()) else {
            return;
        };
        let Ok(mut sighup) = signal(SignalKind::hangup()) else {
            return;
        };

        tokio::select! {
            _ = sigint.recv() => {},
            _ = sigterm.recv() => {},
            _ = sighup.recv() => {},
        }
        restore();
        std::process::exit(130);
    });
}

#[cfg(not(unix))]
pub fn install_signal_handlers() {}

pub struct RawGuard;

impl RawGuard {
    pub fn enable() -> Result<Self> {
        install_signal_handlers();
        crossterm::terminal::enable_raw_mode()?;
        Ok(RawGuard)
    }
}

impl Drop for RawGuard {
    fn drop(&mut self) {
        restore();
    }
}

pub fn size() -> (u16, u16) {
    crossterm::terminal::size().unwrap_or((80, 24))
}
