//! SFTP uploads into the remote inbox.

use anyhow::{Context, Result};
use russh_sftp::client::SftpSession;
use std::path::Path;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::io::AsyncWriteExt;

use crate::config::{InboxScope, Resolved};
use crate::session::{self, Ssh};

/// Dirs already pruned this session — prune each at most once.
static PRUNED: Mutex<Vec<String>> = Mutex::new(Vec::new());

/// Where an upload should land: the current project's `.devbox-inbox/` (scoped
/// via the shell's OSC 7 cwd) or the global inbox. Ensures the dir exists and
/// prunes stale files once per dir per session.
pub async fn upload_dir(ssh: &Ssh, cfg: &Resolved, cwd: Option<&str>) -> String {
    let dir = match (cfg.inbox_scope, cwd) {
        (InboxScope::Project, Some(d)) if d.starts_with('/') => {
            format!("{}/.devbox-inbox", d.trim_end_matches('/'))
        }
        _ => ssh.inbox.clone(),
    };
    let _ = session::ensure_dir(&ssh.sftp, &dir).await;
    prune(ssh, &dir, cfg.inbox_retention_days).await;
    dir
}

async fn prune(ssh: &Ssh, dir: &str, days: u64) {
    if days == 0 {
        return;
    }
    {
        let mut done = PRUNED.lock().unwrap();
        if done.iter().any(|d| d == dir) {
            return;
        }
        done.push(dir.to_string());
    }
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let cutoff = now.saturating_sub(days * 86_400);
    let Ok(entries) = ssh.sftp.read_dir(dir).await else {
        return;
    };
    for e in entries {
        if !e.file_type().is_file() {
            continue;
        }
        let mtime = e.metadata().mtime.unwrap_or(0) as u64;
        if mtime != 0 && mtime < cutoff {
            let _ = ssh.sftp.remove_file(e.path()).await;
        }
    }
}

pub async fn upload_bytes(
    sftp: &SftpSession,
    inbox: &str,
    name: &str,
    data: &[u8],
) -> Result<String> {
    let remote = unique_name(sftp, inbox, name).await;
    let mut file = sftp
        .create(&remote)
        .await
        .with_context(|| format!("create {remote}"))?;
    file.write_all(data).await.context("sftp write")?;
    file.shutdown().await.context("sftp flush")?;
    Ok(remote)
}

pub async fn upload_file(sftp: &SftpSession, inbox: &str, local: &Path) -> Result<String> {
    let data = tokio::fs::read(local)
        .await
        .with_context(|| format!("read {}", local.display()))?;
    let name = local
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "upload.bin".into());
    upload_bytes(sftp, inbox, &sanitize(&name), &data).await
}

pub fn timestamp_name(prefix: &str, ext: &str) -> String {
    format!(
        "{prefix}-{}.{ext}",
        chrono::Local::now().format("%Y%m%d-%H%M%S")
    )
}

fn sanitize(name: &str) -> String {
    name.chars()
        .map(|c| {
            if c == '/' || c == '\\' || c == '\0' {
                '_'
            } else {
                c
            }
        })
        .collect()
}

async fn unique_name(sftp: &SftpSession, inbox: &str, name: &str) -> String {
    let candidate = format!("{}/{}", inbox.trim_end_matches('/'), name);
    if !sftp.try_exists(&candidate).await.unwrap_or(false) {
        return candidate;
    }
    let (stem, ext) = match name.rsplit_once('.') {
        Some((s, e)) => (s.to_string(), format!(".{e}")),
        None => (name.to_string(), String::new()),
    };
    for i in 1..1000 {
        let c = format!("{}/{}-{}{}", inbox.trim_end_matches('/'), stem, i, ext);
        if !sftp.try_exists(&c).await.unwrap_or(false) {
            return c;
        }
    }
    format!(
        "{}/{}-{}{}",
        inbox.trim_end_matches('/'),
        stem,
        std::process::id(),
        ext
    )
}

/// quote a path for shell prompts when it contains awkward characters
pub fn shell_quote(path: &str) -> String {
    if path
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || "/._-~".contains(c))
    {
        path.to_string()
    } else {
        format!("'{}'", path.replace('\'', "'\\''"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quoting() {
        assert_eq!(shell_quote("/a/b/c.png"), "/a/b/c.png");
        assert_eq!(shell_quote("/a/with space.png"), "'/a/with space.png'");
    }

    #[test]
    fn sanitizing() {
        assert_eq!(sanitize("a/b\\c.png"), "a_b_c.png");
    }
}
