# Security notes

A devbox is a disposable machine with your agent credentials on it. Treat it
accordingly.

## What the machine enforces

- **SSH keys only** — `PasswordAuthentication no`, `KbdInteractiveAuthentication no`,
  `PermitRootLogin no` (drop-in `/etc/ssh/sshd_config.d/99-devbox.conf`).
- **Single unprivileged user** (`dev` by default) with passwordless sudo; the
  password itself is locked.
- **Firewall: port 22 only.** Hetzner Cloud Firewall / AWS security group /
  Azure NSG all allow inbound SSH (and ICMP on Hetzner) and nothing else.
  If you run a dev server on the box, reach it through an SSH tunnel:
  `ssh -L 3000:localhost:3000 dev@<ip>` — don't open extra ports.

## What you are responsible for

- **Cloud credentials in GitHub secrets.** Prefer the OIDC modes for
  [AWS](aws.md) and [Azure](azure.md) — no long-lived keys stored at all. For
  Hetzner, use a token scoped to a dedicated project.
- **Who can run workflows.** Anyone with *write* access to your fork can
  deploy/destroy and therefore spend your money. Keep the repo private or
  restrict collaborators.
- **Agent logins live on the box.** `gh auth login`, `codex login`, `claude`
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

## Hardening ideas for later versions

Idle auto-shutdown, fail2ban/SSH rate-limiting, restricting the SSH ingress
CIDR to your IP (one-line change in `terraform/<provider>`), and Tailscale
instead of a public IP.
