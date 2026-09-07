# Security architecture & hardening

A devbox is a disposable machine with your agent credentials on it. Treat it
accordingly.

## Host & network security

- **SSH keys only** — `PasswordAuthentication no`, `KbdInteractiveAuthentication no`,
  `PermitRootLogin no` (drop-in `/etc/ssh/sshd_config.d/99-devbox.conf`).
- **User privileges & Sudo model**:
  - Dev user (`dev` by default) has passwordless sudo (`NOPASSWD:ALL`) for developer workflow convenience (installing system packages, running Docker, system tuning). The account password itself is locked.
  - *Threat model notice*: Because the dev user possesses sudo permissions, untrusted code execution containment does NOT rely on UNIX user boundaries alone; sandboxing and agent tool boundaries (such as Bubblewrap) provide isolation.
- **Dynamic Firewall**:
  - By default without Tailscale, port 22 is open to the internet (`0.0.0.0/0`, `::/0`).
  - When `tailscale_authkey` is configured, **port 22 is automatically closed** to the public internet unless `ssh_allowed_cidrs` is explicitly provided.
  - Custom ingress CIDRs can be specified via `variable "ssh_allowed_cidrs"` across Hetzner, AWS, and Azure.
  - Tailscale WireGuard UDP port `41641` is permitted for direct peer-to-peer tunnels.
- **AWS IMDSv2 Enforcement**:
  - AWS EC2 instance metadata strictly enforces IMDSv2 (`http_tokens = "required"`) with a hop limit of `1`. This blocks SSRF attacks and prevents agents or Docker containers from extracting AWS instance IAM credentials.
- **Credential Scrubbing & Cloud Metadata Realities**:
  - `/etc/devbox/devbox.env` is restricted to permissions `0600` (owned by `root:root`).
  - `TAILSCALE_AUTHKEY` is automatically scrubbed from `/etc/devbox/devbox.env` immediately after `tailscale up`. Sensitive `PROVISIONING_TOKEN` values are wiped from disk immediately after fetching the archive. Child install scripts run with these variables scrubbed from the environment.
  - *Defense-in-depth note*: While on-disk files are scrubbed, cloud metadata services (e.g. Hetzner Cloud Metadata at `169.254.169.254`) and cloud-init local caches (`/var/lib/cloud/instances/*/user-data.txt`) may still retain the initial cloud-init payload. Therefore, scrubbing is defense-in-depth: the primary mitigation is generating **single-use (non-reusable)**, **ephemeral**, and **tagged** Tailscale auth keys (e.g. `tag:devbox`), ensuring any exposed key cannot be reused once registered.

## Agent blast radius & sandbox isolation

- **Unprivileged agent execution**: AI agents run as `$DEVBOX_USER` inside `/workspace`.
- **Codex Bubblewrap Sandbox**: Codex runs tool commands inside an unprivileged Bubblewrap (`bwrap`) container namespace.
- **CLI Sensitive Path Intercept**:
  - The companion `devbox` CLI defaults to `paste_intercept = "ask"`.
  - Sensitive paths (`~/.ssh/*`, `~/.gnupg/*`, `~/.aws/*`, `~/.kube/*`, dot-directories, `id_*`, `*.pem`, `*.key`, `*.pfx`, `*.p12`, `.env*`) trigger an explicit interactive confirmation prompt even if `paste_intercept = "auto"`.
- **MCP Database Server Hardening (`mcp/db`)**:
  - SQLite identifier escaping (`escapeSqliteIdent`) prevents SQL injection on table names, pragma queries, and counts.
  - PostgreSQL connections enforce `SET statement_timeout = '5s'` for read operations and block queries that attempt to modify `statement_timeout`.
  - Dangerous PostgreSQL functions are blocked (`pg_sleep`, `pg_read_file`, `pg_write_file`, `dblink`, `lo_import`, `lo_export`, `set_config`, `pg_terminate_backend`, `pg_cancel_backend`, `pg_reload_conf`, `pg_rotate_logfile`, etc.).
  - *Defense-in-depth note*: Regular expression filtering blocks accidental or common destructive queries by LLMs, but does not replace database-level access controls. Always connect to target databases using dedicated read-only database roles with least-privilege `SELECT` grants.
  - Automatic sourcing of production credentials from arbitrary `.env` files can be disabled via `DEVBOX_DB_DISABLE_ENV=1`.

## Web Gateway Security (`web/`)

The `devbox-web` companion service runs as an unprivileged user systemd service:
- **Binding**: Binds to `HOST=127.0.0.1` on port `7681` by default. Accessible externally via `tailscale serve --bg 7681` (which provides HTTPS under your tailnet name) or an SSH local port forward (`ssh -L 7681:127.0.0.1:7681 dev@<ip>`).
- **Authentication**: Fail-closed token-based authentication via `DEVBOX_WEB_TOKEN` stored in `~/.devbox/web.env` (permissions `0600`). If the token is unset or empty, the server refuses to start. Constant-time comparison (`crypto.timingSafeEqual`) is enforced for API and WebSocket token checks.
- **CSWSH Protection**: Cross-Site WebSocket Hijacking protection by strictly validating the `Origin` header against the exact `Host` header or configured `DEVBOX_ALLOWED_ORIGIN`. Unrestricted wildcard domain suffixes are rejected.
- **Command Injection Prevention**: Uses argument array execution (`spawnSync`/`execFileSync`) rather than shell string interpolation for `tmux` commands, combined with strict session name validation (`/^[a-zA-Z0-9_.-]+$/`).
- **Subresource Integrity (SRI)**: CDN fallbacks for `@xterm/xterm` scripts include cryptographic SRI hashes.

## CLI Cryptographic Dependencies

The companion CLI `russh` dependency is updated to `0.62.7`, resolving pre-release RC dependencies for `curve25519-dalek` and `ed25519-dalek`. Upstream transitive dependencies `ssh-key 0.7.0-rc.11` and `rsa 0.10.0-rc.18` remain inside `russh-keys` until resolved in a future `russh` release.

## Tailscale recommendations

When generating a Tailscale auth key:
- Always generate **single-use (non-reusable)**, **ephemeral** keys tagged with an ACL tag (e.g. `tag:devbox`).
- Ephemeral nodes are automatically removed from your Tailnet when the devbox is destroyed or shut down.
- Single-use tagged keys eliminate personal credential storage and cannot be reused if metadata caches are inspected.

## What you are responsible for

- **Cloud credentials in GitHub secrets.** Prefer the OIDC modes for
  [AWS](aws.md) and [Azure](azure.md) — no long-lived keys stored at all. For
  Hetzner, use a token scoped to a dedicated project.
- **Who can run workflows.** Anyone with *write* access to your fork can
  deploy/destroy and therefore spend your money. Keep the repo private or
  restrict collaborators.
- **Agent logins live on the box.** `gh auth login`, `codex login`, `claude`, `agy`
  store tokens in the dev user's home. Destroying the machine destroys them —
  that's a feature. Don't snapshot the disk into images you share.
- **Destroy when done.** The whole model is deploy → work → destroy. Idle
  machines are both a cost and an attack surface.

## Terraform state

State files contain resource metadata (IPs, resource ids — not your cloud
credentials, not your SSH private key). The bootstrap keeps them in a private
bucket/container in **your** account:

- AWS: versioned S3 bucket, all public access blocked, S3-native locking.
- Azure: storage account with public blob access disabled.
- Hetzner: private Object Storage bucket.

Your **SSH public key** ends up in the state and on the machine — that is what
public keys are for. Your private key never leaves your laptop.

