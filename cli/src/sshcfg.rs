//! Minimal ~/.ssh/config reader: Host blocks with HostName / User / Port / IdentityFile.
//! Supports `*` suffix globs (Host dev-*); enough for aliases, not a full implementation.

#[derive(Debug, Default, Clone)]
pub struct SshHost {
    pub host_name: Option<String>,
    pub user: Option<String>,
    pub port: Option<u16>,
    pub identity_file: Option<String>,
}

fn pattern_matches(pattern: &str, host: &str) -> bool {
    if pattern == host {
        return true;
    }
    if let Some(prefix) = pattern.strip_suffix('*') {
        return host.starts_with(prefix);
    }
    false
}

pub fn lookup(alias: &str) -> SshHost {
    let Some(home) = dirs::home_dir() else {
        return SshHost::default();
    };
    let path = home.join(".ssh/config");
    let Ok(raw) = std::fs::read_to_string(path) else {
        return SshHost::default();
    };
    parse(&raw, alias)
}

pub fn parse(raw: &str, alias: &str) -> SshHost {
    let mut result = SshHost::default();
    let mut in_match = false;
    for line in raw.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (key, value) = match line.split_once(char::is_whitespace) {
            Some((k, v)) => (k.to_lowercase(), v.trim().trim_matches('"').to_string()),
            None => continue,
        };
        if key == "host" {
            in_match = value.split_whitespace().any(|p| pattern_matches(p, alias));
            continue;
        }
        if !in_match {
            continue;
        }
        // first match wins, like OpenSSH
        match key.as_str() {
            "hostname" if result.host_name.is_none() => result.host_name = Some(value),
            "user" if result.user.is_none() => result.user = Some(value),
            "port" if result.port.is_none() => result.port = value.parse().ok(),
            "identityfile" if result.identity_file.is_none() => result.identity_file = Some(value),
            _ => {}
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"
# comment
Host prod
    HostName 203.0.113.7
    User deploy
    Port 2222
    IdentityFile ~/.ssh/prod_ed25519

Host dev-*
    User dev

Host *
    User fallback
"#;

    #[test]
    fn exact_alias() {
        let h = parse(SAMPLE, "prod");
        assert_eq!(h.host_name.as_deref(), Some("203.0.113.7"));
        assert_eq!(h.user.as_deref(), Some("deploy"));
        assert_eq!(h.port, Some(2222));
        assert_eq!(h.identity_file.as_deref(), Some("~/.ssh/prod_ed25519"));
    }

    #[test]
    fn glob_and_fallback() {
        let h = parse(SAMPLE, "dev-box1");
        assert_eq!(h.user.as_deref(), Some("dev"));
        assert!(h.host_name.is_none());
        let f = parse(SAMPLE, "other");
        assert_eq!(f.user.as_deref(), Some("fallback"));
    }
}
