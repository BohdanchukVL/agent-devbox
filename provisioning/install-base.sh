#!/usr/bin/env bash
# Base toolchain. Runs once as root via cloud-init; flags come from
# /etc/devbox/devbox.env. Must stay idempotent — re-running is safe.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

. /etc/devbox/devbox.env

log() { echo "[devbox $(date -u +%H:%M:%S)] $*"; }

log "installing base packages"
apt-get update -y
apt-get install -y --no-install-recommends \
  git curl wget jq unzip zip ripgrep fzf tmux htop \
  build-essential ca-certificates gnupg \
  python3 python3-venv python3-pip pipx

log "installing GitHub CLI"
install -dm 0755 /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list
apt-get update -y
apt-get install -y gh

log "installing Node.js 22 + pnpm"
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs
npm install -g pnpm

if [ "$INSTALL_DOCKER" = "true" ]; then
  log "installing Docker"
  curl -fsSL https://get.docker.com | sh
  usermod -aG docker "$DEVBOX_USER"
  systemctl enable --now docker
fi

log "setting up /workspace"
mkdir -p /workspace
if [ -n "$WORKSPACE_DEVICE" ]; then
  # The volume may attach a bit after boot — wait for the device node.
  for _ in $(seq 1 60); do [ -e "$WORKSPACE_DEVICE" ] && break; sleep 2; done
  if [ -e "$WORKSPACE_DEVICE" ]; then
    blkid "$WORKSPACE_DEVICE" >/dev/null 2>&1 || mkfs.ext4 -L workspace "$WORKSPACE_DEVICE"
    grep -q "$WORKSPACE_DEVICE" /etc/fstab || \
      echo "$WORKSPACE_DEVICE /workspace ext4 defaults,nofail 0 2" >> /etc/fstab
    mountpoint -q /workspace || mount /workspace
  else
    log "WARNING: workspace device $WORKSPACE_DEVICE never appeared; using root disk"
  fi
fi
chown "$DEVBOX_USER:$DEVBOX_USER" /workspace

log "hardening SSH"
cat > /etc/ssh/sshd_config.d/99-devbox.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true

log "base install done"
