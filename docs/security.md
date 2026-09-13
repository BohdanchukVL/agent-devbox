# Security architecture & hardening

A devbox is a disposable machine with your agent credentials on it. Treat it
accordingly.

## Host & network security

- **SSH keys only** — `PasswordAuthentication no`, `KbdInteractiveAuthentication no`,
  `PermitRootLogin no` (drop-in `/etc/ssh/sshd_config.d/99-devbox.conf`).
- **User privileges & Threat model (D1)**:
  - The dev user (`dev` by default) has passwordless sudo (`NOPASSWD:ALL`) and belongs to the `docker` group for developer workflows.
  - *Threat model reality*: `dev` is equivalent to root. UNIX user boundaries are NOT the primary security layer.
  - The security boundary is established by:
    1. **The disposable VM boundary**: The whole environment is created and destroyed on demand; no production keys live permanently on disk.
    2. **Agent tool sandboxes**: Claude Code and Codex execute tool calls within sandboxes where sudo and host escape are restricted.
    3. **Secrets minimization**: Sensitive credentials (`TAILSCALE_AUTHKEY`, `DEVBOX_WEB_TOKEN`) are delivered via short-lived presigned URLs, wiped from disk post-bootstrap, and never stored in cloud-init user-data caches.
    4. **Network & Metadata isolation**: Outbound access to cloud metadata endpoints is blocked for non-root and all container traffic.
    5. **Integrity locks**: Core security files (`sshd_config.d/99-devbox.conf`, `sudoers.d/90-devbox`, `devbox-metadata-guard.service`, `devbox-doctor`) are marked immutable (`chattr +i`) and verified against `/etc/devbox/integrity.sha256`.
       - *Operational procedure for modifications*: To modify any of these files intentionally, an administrator must remove the immutable attribute with `sudo chattr -i <file>`, apply the edit, update `/etc/devbox/integrity.sha256` if applicable, and restore immutability with `sudo chattr +i <file>`.
- **Sudo audit & I/O logging**:
  - Sudo configuration lives in `/etc/sudoers.d/90-devbox` with `log_input, log_output, use_pty, iolog_dir=/var/log/sudo-io`. All sudo invocations and terminal sessions are recorded for forensic audit.
- **Docker Daemon Hardening**:
  - Docker daemon enforces `no-new-privileges: true` by default, preventing container processes from gaining additional privileges via setuid/setgid binaries.
  - If a containerized workload specifically requires setuid privilege switching (e.g. an entrypoint using `gosu` or `su`), it can be explicitly opted out at container runtime using `--security-opt no-new-privileges=false`.
- **Dynamic Firewall**:
  - By default without Tailscale, port 22 is open to the internet (`0.0.0.0/0`, `::/0`).
  - When `tailscale_authkey` is configured, **port 22 is automatically closed** to the public internet unless `ssh_allowed_cidrs` is explicitly provided.
  - Custom ingress CIDRs can be specified via `variable "ssh_allowed_cidrs"` across Hetzner, AWS, and Azure.
  - Tailscale WireGuard UDP port `41641` is permitted for direct peer-to-peer tunnels.
  - **Tailscale SSH is disabled**: `tailscale up` runs without `--ssh` so all incoming connections use standard OpenSSH and `authorized_keys`. `tailscale set --operator=dev` allows the unprivileged user to configure `tailscale serve` without sudo.
- **AWS IMDSv2 & Metadata Guarding**:
  - AWS EC2 instance metadata strictly enforces IMDSv2 (`http_tokens = "required"`) with a hop limit of `1`.
  - In addition, the persistent `devbox-metadata-guard` service enforces iptables rules on `OUTPUT` (non-root) and `DOCKER-USER` (all container traffic) for IPv4 (`169.254.169.254`) and IPv6 (`fd00:ec2::254`). Docker cannot bypass this guard.

## Agent blast radius & sandbox isolation

- **Unprivileged agent execution**: AI agents run as `$DEVBOX_USER` inside `/workspace`.
- **Per-agent sandbox configuration** (provisioned by `install-agents.sh`):
  - **Claude Code**: configured in `~/.claude/settings.json` with strict sandboxing:
    - `sandbox.enabled = true`
    - `sandbox.failIfUnavailable = true`
    - `sandbox.allowUnsandboxedCommands = false` (when `agent_sandbox_strict = true`)
    - `sandbox.credentials = false`: credentials opt-in isolation. When enabled, credentials from host tool configurations (`~/.aws`, `~/.ssh`, `~/.config/gh`, cloud tokens) are shielded from agent tool execution.
    - `sandbox.network.allowedDomains`: restricted to package registries and GitHub (`registry.npmjs.org`, `github.com`, `api.github.com`, `objects.githubusercontent.com`, `crates.io`, `static.crates.io`, `pypi.org`, `files.pythonhosted.org`, `proxy.golang.org`).
    - Agents cannot execute `sudo` inside the sandbox. The human user can execute host commands outside the sandbox via the interactive `!` shell mode or direct terminal.
  - **Codex**: runs in `sandbox_mode = "workspace-write"` with Bubblewrap (`bwrap`).
    - Tool execution is containerized.
    - Write access is constrained to `["/workspace"]`.
    - Networking is enabled (`enable_networking = true`) for package management.
  - **OpenCode / Antigravity**: have no native sandbox mechanisms and operate with the dev user's full privileges. Isolation relies on the disposable VM boundary.
  - **What is NOT protected**: commands run through Claude Code's interactive `!` shell escape, tools invoked under OpenCode or Antigravity, and manual human shell commands.
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
- **CSWSH Protection**: Cross-Site WebSocket Hijacking protection by strictly validating the `Origin` header against the exact `Host` header, `X-Forwarded-Host`, or configured `DEVBOX_ALLOWED_ORIGIN`. Unrestricted wildcard domain suffixes are rejected.
- **DNS Rebinding & Token Primacy**: Origin-to-Host validation does not protect against DNS rebinding (where an attacker's domain resolves to `127.0.0.1`, matching Origin and Host). Therefore, secret token authentication (`DEVBOX_WEB_TOKEN`) is the primary, indispensable boundary protecting WebSockets and APIs; Origin checks serve as defense-in-depth against simple cross-origin requests from third-party websites.
- **Command Injection Prevention**: Uses argument array execution (`spawnSync`/`execFileSync`) rather than shell string interpolation for `tmux` commands, combined with strict session name validation (`/^[a-zA-Z0-9_.-]+$/`).
- **Subresource Integrity (SRI)**: CDN fallbacks for `@xterm/xterm` scripts include cryptographic SRI hashes.

## CLI Cryptographic Dependencies

The companion CLI `russh` dependency is updated to `0.62.7`, resolving pre-release RC dependencies for `curve25519-dalek` and `ed25519-dalek`. Upstream transitive dependencies `ssh-key 0.7.0-rc.11` and `rsa 0.10.0-rc.18` remain inside `russh-keys` until resolved in a future `russh` release.

## Tailscale recommendations & ACL policy

- **Single-use, Ephemeral Keys**:
  Always generate **single-use (non-reusable)**, **ephemeral** keys tagged with an ACL tag (such as `tag:devbox`). Ephemeral nodes are automatically culled from your Tailnet when the devbox VM is terminated.
- **Tailscale OAuth Client Credentials**:
  For CI/CD and automated ephemeral deployments, use Tailscale OAuth client credentials (`TAILSCALE_OAUTH_CLIENT_ID` and `TAILSCALE_OAUTH_CLIENT_SECRET`) with the `devices:write` scope and `tag:devbox` attribute. This enables automated pipelines to mint dynamic, 15-minute ephemeral keys on demand, eliminating static pre-generated tokens entirely.
- **Recommended Destination-Only ACL**:
  Devbox instances are development workstations that may run unverified code or package dependencies. Configure your Tailscale ACL policy so `tag:devbox` is strictly a destination for authorized engineers, with no access to other internal network assets:

```json
{
  "tagOwners": {
    "tag:devbox": ["autogroup:admin"]
  },
  "acls": [
    // Engineers can reach devbox SSH and companion web gateway
    {
      "action": "accept",
      "src": ["autogroup:members"],
      "dst": [
        "tag:devbox:22",
        "tag:devbox:7681",
        "tag:devbox:41641"
      ]
    }
    // Note: tag:devbox has NO outgoing rules to any internal nodes or tags
  ]
}
```

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

