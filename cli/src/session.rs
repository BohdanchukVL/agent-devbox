//! SSH session: connect, host-key TOFU (known_hosts), auth (agent → identity files → password),
//! PTY shell channel + SFTP subsystem channel.

use anyhow::{anyhow, bail, Context, Result};
use russh::client::{self, AuthResult, Handle};
use russh::keys::{load_secret_key, PrivateKeyWithHashAlg, PublicKey};
use russh::Channel;
use russh_sftp::client::SftpSession;
use std::io::Write;
use std::sync::Arc;

use crate::config::Resolved;

pub struct ClientHandler {
    host: String,
    port: u16,
}

impl client::Handler for ClientHandler {
    type Error = anyhow::Error;

    async fn check_server_key(
        &mut self,
        server_public_key: &PublicKey,
    ) -> Result<bool, Self::Error> {
        match russh::keys::check_known_hosts(&self.host, self.port, server_public_key) {
            Ok(true) => Ok(true),
            Ok(false) => {
                // TOFU, like OpenSSH: ask once, then persist
                let fp = server_public_key.fingerprint(Default::default());
                eprint!(
                    "The authenticity of host '{}:{}' can't be established.\nKey fingerprint: {}\nAre you sure you want to continue connecting (yes/no)? ",
                    self.host, self.port, fp
                );
                std::io::stderr().flush().ok();
                let mut answer = String::new();
                std::io::stdin().read_line(&mut answer).ok();
                if answer.trim().eq_ignore_ascii_case("yes")
                    || answer.trim().eq_ignore_ascii_case("y")
                {
                    russh::keys::known_hosts::learn_known_hosts(
                        &self.host,
                        self.port,
                        server_public_key,
                    )
                    .context("write known_hosts")?;
                    Ok(true)
                } else {
                    Ok(false)
                }
            }
            Err(e) => {
                eprintln!("\n@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED @@\n{e}");
                Ok(false)
            }
        }
    }
}

pub struct Ssh {
    pub handle: Handle<ClientHandler>,
    pub shell: Channel<client::Msg>,
    pub sftp: SftpSession,
    /// resolved absolute global fallback inbox dir on the remote
    pub inbox: String,
}

pub async fn connect(cfg: &Resolved) -> Result<Ssh> {
    let ssh_config = Arc::new(client::Config {
        keepalive_interval: Some(std::time::Duration::from_secs(30)),
        ..Default::default()
    });
    let handler = ClientHandler {
        host: cfg.host.clone(),
        port: cfg.port,
    };
    let mut handle = client::connect(ssh_config, (cfg.host.as_str(), cfg.port), handler)
        .await
        .with_context(|| format!("connect {}:{}", cfg.host, cfg.port))?;

    authenticate(&mut handle, cfg).await?;

    let shell = handle
        .channel_open_session()
        .await
        .context("open shell channel")?;
    let (cols, rows) = crossterm::terminal::size().unwrap_or((80, 24));
    let term = std::env::var("TERM").unwrap_or_else(|_| "xterm-256color".into());
    shell
        .request_pty(false, &term, cols as u32, rows as u32, 0, 0, &[])
        .await
        .context("request pty")?;
    match &cfg.remote_command {
        Some(cmd) => shell
            .exec(false, cmd.as_bytes())
            .await
            .context("exec remote command")?,
        None => shell.request_shell(false).await.context("request shell")?,
    }

    let sftp_ch = handle
        .channel_open_session()
        .await
        .context("open sftp channel")?;
    sftp_ch
        .request_subsystem(true, "sftp")
        .await
        .context("request sftp subsystem")?;
    let sftp = SftpSession::new(sftp_ch.into_stream())
        .await
        .context("sftp handshake")?;

    let home = sftp
        .canonicalize(".")
        .await
        .context("resolve remote home")?;
    let home = home.trim_end_matches('/').to_string();
    let inbox = resolve_inbox(&sftp, &home, &cfg.inbox).await?;

    Ok(Ssh {
        handle,
        shell,
        sftp,
        inbox,
    })
}

/// mkdir -p over SFTP
pub async fn ensure_dir(sftp: &SftpSession, dir: &str) -> Result<()> {
    let mut acc = String::new();
    for part in dir.split('/').filter(|p| !p.is_empty()) {
        acc.push('/');
        acc.push_str(part);
        if sftp.try_exists(&acc).await.unwrap_or(false) {
            continue;
        }
        sftp.create_dir(&acc)
            .await
            .map_err(|e| anyhow!("mkdir {acc}: {e}"))?;
    }
    Ok(())
}

async fn authenticate(handle: &mut Handle<ClientHandler>, cfg: &Resolved) -> Result<()> {
    // 1) ssh-agent (unix)
    #[cfg(unix)]
    if let Ok(mut agent) = russh::keys::agent::client::AgentClient::connect_env().await {
        if let Ok(identities) = agent.request_identities().await {
            for identity in identities {
                let russh::keys::agent::AgentIdentity::PublicKey { key, .. } = identity else {
                    continue; // certificates — v0.2
                };
                let hash = handle
                    .best_supported_rsa_hash()
                    .await
                    .ok()
                    .flatten()
                    .flatten();
                match handle
                    .authenticate_publickey_with(&cfg.user, key, hash, &mut agent)
                    .await
                {
                    Ok(AuthResult::Success) => return Ok(()),
                    _ => continue,
                }
            }
        }
    }

    // 2) identity files
    for path in &cfg.identity_files {
        let key = match load_secret_key(path, None) {
            Ok(k) => k,
            Err(_) => continue, // encrypted or unreadable — skip silently
        };
        let hash = handle
            .best_supported_rsa_hash()
            .await
            .ok()
            .flatten()
            .flatten();
        let key = PrivateKeyWithHashAlg::new(Arc::new(key), hash);
        if let Ok(AuthResult::Success) = handle.authenticate_publickey(&cfg.user, key).await {
            return Ok(());
        }
    }

    // 3) password
    for attempt in 0..3 {
        let prompt = if attempt == 0 {
            format!("{}@{}'s password: ", cfg.user, cfg.host)
        } else {
            "Permission denied, please try again: ".into()
        };
        let password = rpassword::prompt_password(prompt).context("read password")?;
        if let Ok(AuthResult::Success) = handle.authenticate_password(&cfg.user, &password).await {
            return Ok(());
        }
    }

    bail!("authentication failed for {}@{}", cfg.user, cfg.host)
}

/// `~/x` → remote-home-relative; ensure the directory exists (mkdir -p semantics).
async fn resolve_inbox(sftp: &SftpSession, home: &str, inbox: &str) -> Result<String> {
    let base = match inbox.strip_prefix("~/") {
        Some(rest) => format!("{home}/{rest}"),
        None => inbox.to_string(),
    };
    ensure_dir(sftp, &base).await?;
    Ok(base)
}
