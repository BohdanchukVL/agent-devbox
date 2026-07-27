# Hetzner setup

The fastest provider to get started with — one API token, one storage key pair.

## 1. Create credentials

**Cloud API token** (controls servers):
1. [Hetzner Cloud Console](https://console.hetzner.cloud/) → your project → *Security → API tokens*.
2. Generate a token with **Read & Write** permissions.

**Object Storage credentials** (stores Terraform state):
1. Same project → *Security → S3 credentials* (Object Storage).
2. Generate a key pair. Object Storage is billed separately (a few cents/month for state).

## 2. Add GitHub secrets

*Repo → Settings → Secrets and variables → Actions → New repository secret*:

| Secret | Value |
|---|---|
| `HCLOUD_TOKEN` | the Cloud API token |
| `HETZNER_S3_ACCESS_KEY` | Object Storage access key |
| `HETZNER_S3_SECRET_KEY` | Object Storage secret key |
| `SSH_PUBLIC_KEY` | your public key, e.g. `ssh-ed25519 AAAA... you@laptop` |

Optional repository **variable**: `HETZNER_STATE_LOCATION` — Object Storage
location for the state bucket (`fsn1` default; also `nbg1`, `hel1`).

## 3. Deploy

*Actions → Deploy to Hetzner → Run workflow*. Parameters:

| Input | Meaning | Default |
|---|---|---|
| Server size | `cx23` (2 vCPU/4 GB) … `cx53` (16 vCPU/32 GB), `cpx32`/`cpx42` (performance) | `cx33` |
| Location | `nbg1` Nuremberg, `fsn1` Falkenstein, `hel1` Helsinki | `nbg1` |
| Workspace volume | GB for a dedicated `/workspace` volume; `0` = root disk | `80` |
| Install Docker / Codex / Claude Code / OpenCode / Antigravity / Browser | toggles | ✔ / ✔ / ✔ / ✘ / ✘ / ✔ |

The first run automatically creates the state bucket
(`tfstate-agent-devbox-<owner>`) in Object Storage. Re-running the workflow
**updates** the existing server (e.g. to resize, change the location, or flip
an install toggle) instead of creating a second one.

> Changing `server_type`, `location`, or the install toggles replaces the
> server (user data / placement changes force recreation). With a workspace
> volume enabled your `/workspace` data survives `server_type` changes within
> the same location.

## 4. Connect

The workflow summary prints the IP:

```bash
ssh dev@<ip>
```

Provisioning continues for ~3–5 minutes after the machine boots; the login
banner shows the current status. Watch it with
`tail -f /var/log/devbox-install.log`.

## 5. Destroy

*Actions → Destroy Hetzner environment → Run workflow* → type `destroy` in the
confirm field. This deletes the server, firewall, SSH key **and the workspace
volume**. The state bucket is kept (it is essentially free and makes the next
deploy instant).
