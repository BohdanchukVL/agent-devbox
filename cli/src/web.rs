//! `devbox web <target>`: ask the devbox for its web gateway URL and show it
//! as a QR code, so a phone can open the terminal without typing anything.

use anyhow::{bail, Context, Result};
use qrcode::render::unicode::Dense1x2;
use qrcode::QrCode;
use serde::Deserialize;

use crate::config::Resolved;
use crate::session;

/// Output of `devbox-web-url --json` on the remote.
#[derive(Debug, Deserialize)]
struct WebUrl {
    url: String,
    /// `tailscale` | `token`
    auth: String,
    /// `serve` | `tailnet` | `local`
    #[serde(default)]
    via: String,
}

const DEFAULT_PORT: u16 = 7681;

pub async fn run(cfg: Resolved, no_qr: bool, with_token: bool) -> Result<()> {
    let handle = session::open(&cfg).await?;

    let mut command = String::from("bash -lc '\"$HOME\"/.devbox/bin/devbox-web-url --json");
    if with_token {
        command.push_str(" --with-token");
    }
    command.push('\'');

    let out = session::exec_capture(&handle, &command).await;
    handle
        .disconnect(russh::Disconnect::ByApplication, "", "")
        .await
        .ok();
    let out = out?;

    if out.status == 127 || (out.status == 0 && out.stdout.trim().is_empty()) {
        bail!(
            "devbox-web-url not found on {}: the machine was provisioned before v0.4.1",
            cfg.host
        );
    }
    if out.status != 0 {
        let detail = if out.stderr.trim().is_empty() {
            out.stdout.trim()
        } else {
            out.stderr.trim()
        };
        bail!(
            "devbox-web-url failed on {} (exit {}): {detail}",
            cfg.host,
            out.status
        );
    }

    let info = parse_web_url(&out.stdout)
        .with_context(|| format!("unexpected devbox-web-url output: {}", out.stdout.trim()))?;

    println!("[devbox] web gateway: {}", info.url);
    let auth = match info.auth.as_str() {
        "tailscale" => "tailscale (tailnet identity)".to_string(),
        "token" => "token (shared secret)".to_string(),
        other => other.to_string(),
    };
    println!("[devbox] auth: {auth}");
    if info.via == "local" {
        let port = url_port(&info.url).unwrap_or(DEFAULT_PORT);
        let ssh_port = if cfg.port == 22 {
            String::new()
        } else {
            format!(" -p {}", cfg.port)
        };
        println!(
            "[devbox] gateway is not on the tailnet; use: ssh -L {port}:127.0.0.1:{port}{ssh_port} {}@{}",
            cfg.user, cfg.host
        );
    }

    if !no_qr {
        println!();
        println!("{}", render_qr(&info.url)?);
    }
    Ok(())
}

/// The JSON line of the script's output. A login shell may print unrelated
/// lines first (profile noise), so take the first line that looks like JSON.
fn parse_web_url(stdout: &str) -> Result<WebUrl> {
    let line = stdout
        .lines()
        .map(str::trim)
        .find(|l| l.starts_with('{'))
        .context("no JSON line")?;
    serde_json::from_str(line).context("parse JSON")
}

/// Explicit port of an `http(s)://host[:port]/...` URL.
fn url_port(url: &str) -> Option<u16> {
    let rest = url.split_once("://")?.1;
    let authority = rest.split(['/', '?', '#']).next()?;
    let host_port = authority.rsplit_once('@').map_or(authority, |(_, hp)| hp);
    if host_port.ends_with(']') {
        return None; // bare IPv6 literal, no port
    }
    host_port.rsplit_once(':')?.1.parse().ok()
}

/// QR code as half-block unicode art (two modules per row), with a quiet zone.
fn render_qr(text: &str) -> Result<String> {
    let code = QrCode::new(text.as_bytes()).context("encode QR code")?;
    Ok(code.render::<Dense1x2>().quiet_zone(true).build())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn qr_renders_terminal_art() {
        let out = render_qr("http://agent-devbox-1.tailxyz.ts.net:7681/").unwrap();
        assert!(!out.is_empty());
        assert!(out.lines().count() > 10, "got:\n{out}");
    }

    #[test]
    fn parses_json_line_after_profile_noise() {
        let s = "Welcome!\n{\"url\":\"http://h:7681/\",\"auth\":\"token\",\"via\":\"local\"}\n";
        let w = parse_web_url(s).unwrap();
        assert_eq!(w.url, "http://h:7681/");
        assert_eq!(w.auth, "token");
        assert_eq!(w.via, "local");
        assert!(parse_web_url("nothing here").is_err());
    }

    #[test]
    fn extracts_url_port() {
        assert_eq!(url_port("http://h.ts.net:7681/"), Some(7681));
        assert_eq!(url_port("http://h.ts.net:7681/?token=x"), Some(7681));
        assert_eq!(url_port("https://h.ts.net/"), None);
        assert_eq!(url_port("http://[::1]/"), None);
        assert_eq!(url_port("garbage"), None);
    }
}
