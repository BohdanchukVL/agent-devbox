# State Migration & Upgrade Guide — v0.4.0

This guide details the procedure for upgrading existing deployments to **v0.4.0** (or managing the live Hetzner instance `178.105.227.8`).

---

## 1. Background & Root Cause of Server Replacement

In **v0.3.x**, the server recreation trigger was defined as:

```hcl
resource "terraform_data" "payload" {
  input = join(":", [
    var.git_ref, var.server_type, var.install_docker, var.install_codex, var.install_claude,
    var.install_opencode, var.install_antigravity, var.install_browser, var.username,
    sha256(var.ssh_public_key), sha256(var.tailscale_authkey), sha256(var.web_token),
  ])
}
```

In **v0.4.0** (WP-2 & WP-3):
1. Common logic is encapsulated in `module.core`.
2. Secrets (`TAILSCALE_AUTHKEY`, `DEVBOX_WEB_TOKEN`) are decoupled from user-data and delivered via ephemeral presigned URLs. Consequently, `sha256(var.tailscale_authkey)` and `sha256(var.web_token)` are removed from `replace_triggers` so secret rotation does not cause server destruction.
3. The deployed server `178.105.227.8` has a recorded `terraform_data.payload` in state corresponding to its original deploy ref and secret hashes.

A standard `terraform apply` against this state will detect that `terraform_data.payload.input` has changed, triggering:

```hcl
lifecycle {
  replace_triggered_by = [terraform_data.payload]
}
```

This causes Terraform to schedule `hcloud_server.this` for **destruction and replacement**.

---

## 2. Upgrade Options for 178.105.227.8

### Option A: Fresh Server Rebuild (Recommended per Roadmap §7)

As noted in the roadmap:
> *Задеплоєна машина 178.105.227.8 після v0.4.0 потребує пересоздання: home втрачається, логіни агентів доведеться повторити. Volume `/workspace` лишається.*

Because all persistent project code and repositories reside on the dedicated volume (`/workspace`), the server is designed to be disposable.

#### Rebuild Procedure:
1. **Backup Home Directory Artifacts (from live machine)**:
   ```bash
   ssh dev@178.105.227.8
   # Backup any agent configs, tokens, or custom dotfiles to /workspace
   mkdir -p /workspace/.devbox-backup
   cp -r ~/.claude.json ~/.config ~/.ssh/authorized_keys /workspace/.devbox-backup/ 2>/dev/null || true
   exit
   ```
2. **Apply Terraform v0.4.0**:
   Run the deployment workflow or execute locally:
   ```bash
   cd terraform/hetzner
   terraform apply
   ```
3. **Verification**:
   - Volume re-attaches automatically to `/workspace`.
   - Sudoers drop-in, metadata guard, and sandboxes are active out of the box.
   - Run readiness check:
     ```bash
     ssh dev@<NEW_IP> "sudo devbox-doctor --strict && sudo devbox-doctor --manifest"
     ```
4. **Restore Home Configuration**:
   ```bash
   ssh dev@<NEW_IP>
   [ -d /workspace/.devbox-backup ] && cp -rn /workspace/.devbox-backup/.* ~/ 2>/dev/null || true
   ```

---

### Option B: State Surgery (In-Place Upgrade Without Recreation)

If you must preserve the live server instance `178.105.227.8` and prevent Terraform from recreating it, execute the following state surgery:

#### Step 1: Backup State
```bash
cd terraform/hetzner
terraform state pull > state-backup-$(date +%s).json
```

#### Step 2: Remove Trigger from State
Removing `terraform_data.payload` clears the replacement dependency:
```bash
terraform state rm terraform_data.payload
```

#### Step 3: Recreate Trigger Resource
Target only `terraform_data.payload` so Terraform records the new trigger string without touching `hcloud_server`:
```bash
terraform apply -target=terraform_data.payload
```

#### Step 4: Verify Plan
Run a plan to confirm `hcloud_server.this` will NOT be destroyed:
```bash
terraform plan
```
**Required outcome**: Plan must report `0 to destroy`.

> [!NOTE]
> **SSH Key Compatibility**: `hcloud_ssh_key.this` remains defined as a standard resource without counts or dynamic lookups. Your existing `hcloud_ssh_key.this` in state is preserved untouched, preventing any ID changes or `ForceNew` server recreations.

#### Step 5: In-Place Host Hardening (Catching up on v0.4.0 security)
Because `user_data` has `ignore_changes = [user_data]`, an existing server does not automatically run updated cloud-init scripts. Apply the v0.4.0 hardening manually on the host:

```bash
ssh dev@178.105.227.8 "sudo bash -s" << EOF
# 1. Update metadata guard with DOCKER-USER chain
cat > /usr/local/bin/devbox-metadata-guard << GUARD
#!/usr/bin/env bash
set -euo pipefail
METADATA_IP4="169.254.169.254"
METADATA_IP6="fd00:ec2::254"
if command -v iptables >/dev/null 2>&1; then
  iptables -C OUTPUT -m owner ! --uid-owner 0 -d "$METADATA_IP4" -j DROP 2>/dev/null ||     iptables -A OUTPUT -m owner ! --uid-owner 0 -d "$METADATA_IP4" -j DROP 2>/dev/null || true
  iptables -N DOCKER-USER 2>/dev/null || true
  iptables -C DOCKER-USER -d "$METADATA_IP4" -j DROP 2>/dev/null ||     iptables -I DOCKER-USER -d "$METADATA_IP4" -j DROP 2>/dev/null || true
fi
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -C OUTPUT -m owner ! --uid-owner 0 -d "$METADATA_IP6" -j DROP 2>/dev/null ||     ip6tables -A OUTPUT -m owner ! --uid-owner 0 -d "$METADATA_IP6" -j DROP 2>/dev/null || true
  ip6tables -N DOCKER-USER 2>/dev/null || true
  ip6tables -C DOCKER-USER -d "$METADATA_IP6" -j DROP 2>/dev/null ||     ip6tables -I DOCKER-USER -d "$METADATA_IP6" -j DROP 2>/dev/null || true
fi
GUARD
chmod 0755 /usr/local/bin/devbox-metadata-guard
/usr/local/bin/devbox-metadata-guard

# 2. Add Docker ExecStartPost drop-in
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/devbox-guard.conf << CONF
[Unit]
Wants=devbox-metadata-guard.service
After=devbox-metadata-guard.service

[Service]
ExecStartPost=/usr/local/bin/devbox-metadata-guard
CONF
systemctl daemon-reload

# 3. Sudoers audit configuration
cat > /etc/sudoers.d/90-devbox << SUDO
dev ALL=(ALL) NOPASSWD:ALL
Defaults:dev log_input, log_output, use_pty, iolog_dir=/var/log/sudo-io
SUDO
chmod 0440 /etc/sudoers.d/90-devbox
mkdir -p /var/log/sudo-io
chmod 0700 /var/log/sudo-io
visudo -cf /etc/sudoers.d/90-devbox

# 4. Verify doctor
/usr/local/bin/devbox-doctor --strict
"EOF"
```
