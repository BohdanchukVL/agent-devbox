# Security architecture & hardening

A devbox is a disposable machine with your agent credentials on it. Treat it
accordingly.

## Host & network security

- **SSH keys only** — `PasswordAuthentication no`, `KbdInteractiveAuthentication no`,
  `PermitRootLogin no` (drop-in `/etc/ssh/sshd_config.d/99-devbox.conf`).
- **Single unprivileged user** (`dev` by default) with passwordless sudo; the
  password itself is locked.
- **Dynamic Firewall**:
  - By default without Tailscale, port 22 is open to the internet (`0.0.0.0/0`, `::/0`).
  - When `tailscale_authkey` is configured, **port 22 is automatically closed** to the public internet unless `ssh_allowed_cidrs` is explicitly provided.
  - Custom ingress CIDRs can be specified via `variable "ssh_allowed_cidrs"` across Hetzner, AWS, and Azure.
  - Tailscale WireGuard UDP port `41641` is permitted for direct peer-to-peer tunnels.
- **AWS IMDSv2 Enforcement**:
  - AWS EC2 instance metadata strictly enforces IMDSv2 (`http_tokens = "required"`) with a hop limit of `1`. This blocks SSRF attacks and prevents agents or Docker containers from extracting AWS instance IAM credentials.
- **Credential Scrubbing & File Hardening**:
  - `/etc/devbox/devbox.env` is restricted to permissions `0600` (owned by `root:root`).
  - `TAILSCALE_AUTHKEY` is automatically scrubbed from `/etc/devbox/devbox.env` immediately after `tailscale up`.
  - Sensitive `PROVISIONING_TOKEN` values are wiped from disk immediately after fetching the archive.

## Agent blast radius & sandbox isolation

- **Unprivileged agent execution**: AI agents run as the unprivileged `$DEVBOX_USER` inside `/workspace`.
- **Codex Bubblewrap Sandbox**: Codex runs tool commands inside an unprivileged Bubblewrap (`bwrap`) container namespace.
- **CLI Sensitive Path Intercept**:
  - The companion `devbox` CLI defaults to `paste_intercept = "ask"`.
  - Sensitive paths (`~/.ssh/*`, `~/.gnupg/*`, `id_*`, `*.pem`, `*.key`, `*.pfx`, `*.p12`, `.env*`) trigger an explicit interactive confirmation prompt even if `paste_intercept = "auto"`.
- **MCP Database Server Hardening (`mcp/db`)**:
  - SQLite identifier escaping (`escapeSqliteIdent`) prevents SQL injection on table names, pragma queries, and counts.
  - PostgreSQL connections enforce `SET statement_timeout = '5s'` for read operations.
  - Dangerous PostgreSQL functions are blocked (`pg_sleep`, `pg_read_file`, `pg_write_file`, `dblink`, `lo_import`, `lo_export`, etc.).
  - Automatic sourcing of production credentials from arbitrary `.env` files can be disabled via `DEVBOX_DB_DISABLE_ENV=1`.

## Web Gateway Security (`web/`)

The `devbox-web` companion service runs as an unprivileged user systemd service:
- **Binding**: Binds to `HOST=127.0.0.1` by default (accessible via Tailscale or reverse proxy).
- **Authentication**: Token-based authentication via `DEVBOX_WEB_TOKEN` stored in `~/.devbox/web.env` (permissions `0600`). Required for both HTTP APIs and WebSocket upgrade.
- **CSWSH Protection**: Cross-Site WebSocket Hijacking protection by validating the `Origin` header against the `Host` header and authorized origins.
- **Command Injection Prevention**: Uses argument array execution (`spawnSync`/`execFileSync`) rather than shell string interpolation for `tmux` commands, combined with strict session name validation (`/^[a-zA-Z0-9_.-]+$/`).
- **Subresource Integrity (SRI)**: CDN fallbacks for `@xterm/xterm` scripts include cryptographic SRI hashes.

## Tailscale recommendation

When generating a Tailscale auth key:
- Prefer **ephemeral keys** tagged with an ACL tag (e.g. `tag:devbox`).
- Ephemeral nodes are automatically removed from your Tailnet when the devbox is destroyed or shut down.
- Tagged keys eliminate the need to store personal Tailscale credentials on the machine.

## Terraform state

State files contain resource metadata (IPs, resource ids — not your cloud
credentials, not your SSH private key). The bootstrap keeps them in a private
bucket/container in **your** account:

- AWS: versioned S3 bucket, all public access blocked, S3-native locking.
- Azure: storage account with public blob access disabled.
- Hetzner: private Object Storage bucket.

Your **SSH public key** ends up in the state and on the machine — that is what
public keys are for. Your private key never leaves your laptop.

