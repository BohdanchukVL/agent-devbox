//! Target resolution: devbox config (~/.config/devbox/config.toml) → ~/.ssh/config → [user@]host.

use anyhow::{Context, Result};
use serde::Deserialize;
use std::collections::HashMap;
use std::path::PathBuf;

use crate::sshcfg;

/// What to do when the remote emits an OSC 52 clipboard write.
/// Reads (the `;?` query form) are never answered, regardless of policy —
/// clipboard reading over SSH is a secret-exfiltration vector and every
/// modern terminal treats it as such (write-only is the industry consensus).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Osc52Policy {
    /// write silently (v0.1 behavior)
    Allow,
    /// write + status line with size, sanitized preview and a newline warning
    Notify,
    /// hold the payload and ask y/n in the session before writing
    Ask,
    /// drop the write, show a status line
    Deny,
}

impl Osc52Policy {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "allow" => Some(Self::Allow),
            "notify" => Some(Self::Notify),
            "ask" => Some(Self::Ask),
            "deny" => Some(Self::Deny),
            _ => None,
        }
    }
}

/// How devbox surfaces its own status/prompt lines. Inline writes corrupt a
/// full-screen TUI (e.g. Claude Code) that owns the screen, so `auto` routes
/// them to an OSC 9 desktop notification whenever the remote app is active.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StatusMode {
    /// notification when a remote TUI is active, inline otherwise (default)
    Auto,
    /// always inline
    Inline,
    /// always an OSC 9 desktop notification
    Notify,
    /// no status output at all
    Quiet,
}

impl StatusMode {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "auto" => Some(Self::Auto),
            "inline" => Some(Self::Inline),
            "notify" => Some(Self::Notify),
            "quiet" => Some(Self::Quiet),
            _ => None,
        }
    }
}

/// What to do when a native paste (⌘V / drag-and-drop) on stdin turns out to
/// be a set of existing local file paths.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PasteIntercept {
    /// upload and substitute remote paths, with a status line (default)
    Auto,
    /// ask y/n before uploading
    Ask,
    /// never intercept — paste the literal text through
    Off,
}

impl PasteIntercept {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "auto" => Some(Self::Auto),
            "ask" => Some(Self::Ask),
            "off" => Some(Self::Off),
            _ => None,
        }
    }
}

/// Where uploads land on the remote.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InboxScope {
    /// current project dir's `.devbox-inbox/` (via OSC 7 cwd), else the global inbox
    Project,
    /// always the single global inbox
    Global,
}

impl InboxScope {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "project" => Some(Self::Project),
            "global" => Some(Self::Global),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Resolved {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub identity_files: Vec<PathBuf>,
    /// global fallback inbox (used when scope is global, or cwd is unknown)
    pub inbox: String,
    /// how uploads are scoped on the remote
    pub inbox_scope: InboxScope,
    /// delete uploads older than this many days on first use of a dir (0 = keep)
    pub inbox_retention_days: u64,
    /// template for what gets typed into the remote prompt; `{path}` is replaced
    pub paste_template: String,
    /// leader byte (default Ctrl+G = 0x07)
    pub leader: u8,
    /// policy for remote OSC 52 clipboard writes
    pub osc52: Osc52Policy,
    /// OSC 52 payloads above this size are dropped (xterm convention: ~100 KB)
    pub osc52_max_bytes: usize,
    /// intercept native pastes that are local file paths → upload
    pub paste_intercept: PasteIntercept,
    /// command to exec instead of a login shell (e.g. `tmux new -A -s main`)
    pub remote_command: Option<String>,
    /// how long after the leader key to wait for the command key
    pub leader_timeout: std::time::Duration,
    /// how status/prompt lines are surfaced (inline vs desktop notification)
    pub status: StatusMode,
}

#[derive(Deserialize, Default)]
struct FileConfig {
    #[serde(default)]
    defaults: Defaults,
    #[serde(default)]
    hosts: HashMap<String, HostEntry>,
}

#[derive(Deserialize, Default)]
struct Defaults {
    inbox: Option<String>,
    paste_template: Option<String>,
    leader: Option<String>,
    osc52: Option<String>,
    osc52_max_bytes: Option<usize>,
    paste_intercept: Option<String>,
    remote_command: Option<String>,
    leader_timeout_ms: Option<u64>,
    status: Option<String>,
    inbox_scope: Option<String>,
    inbox_retention_days: Option<u64>,
}

#[derive(Deserialize)]
struct HostEntry {
    host: String,
    port: Option<u16>,
    user: Option<String>,
    identity_file: Option<String>,
    inbox: Option<String>,
    paste_template: Option<String>,
    osc52: Option<String>,
    paste_intercept: Option<String>,
    remote_command: Option<String>,
}

fn parse_paste(s: Option<&str>, fallback: PasteIntercept) -> PasteIntercept {
    match s {
        None => fallback,
        Some(v) => PasteIntercept::parse(v).unwrap_or_else(|| {
            eprintln!("[devbox] unknown paste_intercept '{v}' — using 'auto' (auto|ask|off)");
            PasteIntercept::Auto
        }),
    }
}

fn parse_osc52(s: Option<&str>, fallback: Osc52Policy) -> Osc52Policy {
    match s {
        None => fallback,
        Some(v) => Osc52Policy::parse(v).unwrap_or_else(|| {
            eprintln!(
                "[devbox] unknown osc52 policy '{v}' — using 'notify' (allow|notify|ask|deny)"
            );
            Osc52Policy::Notify
        }),
    }
}

fn expand_home(p: &str) -> PathBuf {
    if let Some(rest) = p.strip_prefix("~/") {
        if let Some(home) = dirs::home_dir() {
            return home.join(rest);
        }
    }
    PathBuf::from(p)
}

fn parse_leader(s: &str) -> u8 {
    let lower = s.to_lowercase();
    if let Some(ch) = lower.strip_prefix("ctrl+").and_then(|c| c.chars().next()) {
        if ch.is_ascii_lowercase() {
            return (ch as u8) - b'a' + 1;
        }
    }
    0x07
}

fn default_identities() -> Vec<PathBuf> {
    let Some(home) = dirs::home_dir() else {
        return vec![];
    };
    ["id_ed25519", "id_rsa", "id_ecdsa"]
        .iter()
        .map(|n| home.join(".ssh").join(n))
        .filter(|p| p.exists())
        .collect()
}

pub fn resolve(
    target: &str,
    port: Option<u16>,
    identity: Option<String>,
    inbox: Option<String>,
) -> Result<Resolved> {
    let cfg: FileConfig = match dirs::config_dir().map(|d| d.join("devbox/config.toml")) {
        Some(path) if path.exists() => {
            let raw = std::fs::read_to_string(&path).context("read devbox config")?;
            toml::from_str(&raw).context("parse devbox config")?
        }
        _ => FileConfig::default(),
    };

    let default_inbox = cfg
        .defaults
        .inbox
        .clone()
        .unwrap_or_else(|| "~/.devbox/inbox".into());
    let default_template = cfg
        .defaults
        .paste_template
        .clone()
        .unwrap_or_else(|| "{path} ".into());
    let leader = cfg
        .defaults
        .leader
        .as_deref()
        .map(parse_leader)
        .unwrap_or(0x07);
    let default_osc52 = parse_osc52(cfg.defaults.osc52.as_deref(), Osc52Policy::Notify);
    let osc52_max_bytes = cfg.defaults.osc52_max_bytes.unwrap_or(100_000);
    let leader_timeout =
        std::time::Duration::from_millis(cfg.defaults.leader_timeout_ms.unwrap_or(1500));
    let status = match cfg.defaults.status.as_deref() {
        None => StatusMode::Auto,
        Some(v) => StatusMode::parse(v).unwrap_or_else(|| {
            eprintln!("[devbox] unknown status '{v}' — using 'auto' (auto|inline|notify|quiet)");
            StatusMode::Auto
        }),
    };
    let default_command = cfg.defaults.remote_command.clone();
    let default_paste = parse_paste(
        cfg.defaults.paste_intercept.as_deref(),
        PasteIntercept::Auto,
    );
    let inbox_scope = match cfg.defaults.inbox_scope.as_deref() {
        None => InboxScope::Project,
        Some(v) => InboxScope::parse(v).unwrap_or_else(|| {
            eprintln!("[devbox] unknown inbox_scope '{v}' — using 'project' (project|global)");
            InboxScope::Project
        }),
    };
    let inbox_retention_days = cfg.defaults.inbox_retention_days.unwrap_or(7);

    // 1) devbox config alias
    if let Some(entry) = cfg.hosts.get(target) {
        let user = entry.user.clone().map(Ok).unwrap_or_else(whoami)?;
        return Ok(Resolved {
            host: entry.host.clone(),
            port: port.or(entry.port).unwrap_or(22),
            user,
            identity_files: identity
                .as_deref()
                .or(entry.identity_file.as_deref())
                .map(|p| vec![expand_home(p)])
                .unwrap_or_else(default_identities),
            inbox: inbox
                .clone()
                .or_else(|| entry.inbox.clone())
                .unwrap_or(default_inbox),
            inbox_scope,
            inbox_retention_days,
            paste_template: entry.paste_template.clone().unwrap_or(default_template),
            leader,
            osc52: parse_osc52(entry.osc52.as_deref(), default_osc52),
            osc52_max_bytes,
            paste_intercept: parse_paste(entry.paste_intercept.as_deref(), default_paste),
            remote_command: entry.remote_command.clone().or(default_command),
            leader_timeout,
            status,
        });
    }

    // 2) [user@]host, enriched from ~/.ssh/config
    let (user_part, host_part) = match target.split_once('@') {
        Some((u, h)) => (Some(u.to_string()), h.to_string()),
        None => (None, target.to_string()),
    };
    let ssh = sshcfg::lookup(&host_part);

    let user = user_part
        .or(ssh.user.clone())
        .map(Ok)
        .unwrap_or_else(whoami)?;
    let host = ssh.host_name.clone().unwrap_or(host_part.clone());
    let identity_files = identity
        .as_deref()
        .map(|p| vec![expand_home(p)])
        .or_else(|| ssh.identity_file.as_ref().map(|p| vec![expand_home(p)]))
        .unwrap_or_else(default_identities);

    Ok(Resolved {
        host,
        port: port.or(ssh.port).unwrap_or(22),
        user,
        identity_files,
        inbox: inbox.unwrap_or(default_inbox),
        inbox_scope,
        inbox_retention_days,
        paste_template: default_template,
        leader,
        osc52: default_osc52,
        osc52_max_bytes,
        paste_intercept: default_paste,
        remote_command: default_command,
        leader_timeout,
        status,
    })
}

fn whoami() -> Result<String> {
    std::env::var("USER")
        .or_else(|_| std::env::var("USERNAME"))
        .context("cannot determine the remote user: pass user@host or set User in ~/.ssh/config")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn osc52_policy_parsing() {
        assert_eq!(Osc52Policy::parse("allow"), Some(Osc52Policy::Allow));
        assert_eq!(Osc52Policy::parse("notify"), Some(Osc52Policy::Notify));
        assert_eq!(Osc52Policy::parse("ask"), Some(Osc52Policy::Ask));
        assert_eq!(Osc52Policy::parse("deny"), Some(Osc52Policy::Deny));
        assert_eq!(Osc52Policy::parse("yolo"), None);
        // unknown value falls back to notify, not to the (possibly laxer) default
        assert_eq!(
            parse_osc52(Some("yolo"), Osc52Policy::Allow),
            Osc52Policy::Notify
        );
        assert_eq!(parse_osc52(None, Osc52Policy::Deny), Osc52Policy::Deny);
    }
}
