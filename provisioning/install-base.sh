#!/usr/bin/env bash
# Base toolchain. Runs once as root via cloud-init; flags come from
# /etc/devbox/devbox.env. Must stay idempotent — re-running is safe.
set -euo pipefail
trap 'touch /etc/devbox/.failed 2>/dev/null || true' ERR
export DEBIAN_FRONTEND=noninteractive

# shellcheck source=/dev/null
. /etc/devbox/devbox.env
# shellcheck source=/dev/null
. /opt/devbox/versions.env 2>/dev/null || . /opt/devbox/provisioning/versions.env 2>/dev/null || true

log() { echo "[devbox $(date -u +%H:%M:%S)] $*"; }

log "ensuring universe repository"
if ! grep -q "universe" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
  apt-get update -y
  apt-get install -y --no-install-recommends software-properties-common || true
  add-apt-repository -y universe || true
fi

if [ ! -f /swapfile ] && [ "$(swapon --show --noheadings 2>/dev/null | wc -l)" -eq 0 ]; then
  log "configuring 2GB swap file for low-memory safety"
  fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

log "installing base packages"
apt-get update -y
apt-get install -y --no-install-recommends \
  git curl wget jq unzip zip ripgrep fzf tmux htop bubblewrap qrencode \
  rsync socat dnsutils strace ncdu locales \
  build-essential ca-certificates gnupg \
  python3 python3-venv python3-pip pipx \
  universal-ctags golang-go

log "configuring UTF-8 locale and tmux UTF-8 wrapper"
locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 >/dev/null 2>&1 || true

if [ -f /usr/bin/tmux ] && [ ! -f /usr/bin/tmux.bin ]; then
  dpkg-divert --add --rename --divert /usr/bin/tmux.bin /usr/bin/tmux
  cat << 'EOF' > /usr/bin/tmux
#!/bin/sh
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"
export LC_CTYPE="${LC_CTYPE:-en_US.UTF-8}"
exec /usr/bin/tmux.bin -u "$@"
EOF
  chmod 0755 /usr/bin/tmux
  ln -sf /usr/bin/tmux /usr/local/bin/tmux
fi

log "configuring unprivileged user namespaces for bubblewrap sandbox"
if [ -d /etc/apparmor.d ] && command -v apparmor_parser >/dev/null 2>&1; then
  cat > /etc/apparmor.d/bwrap-userns-restrict <<'EOF'
abi <abi/4.0>,
include <tunables/global>

profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,
}
EOF
  apparmor_parser -r /etc/apparmor.d/bwrap-userns-restrict 2>/dev/null || true
fi

log "installing GitHub CLI"
install -dm 0755 /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list
apt-get update -y
apt-get install -y gh

pin() {
  local var_name="$1"
  local fallback="${2:-latest}"
  if [ "${DEVBOX_RELEASE_CHANNEL:-stable}" = "stable" ]; then
    echo "${!var_name:-$fallback}"
  else
    echo "latest"
  fi
}

log "installing Node.js ${NODE_MAJOR:-22} + pnpm $(pin PNPM_VERSION 9.15.9)"
curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR:-22}.x" | bash -
apt-get install -y nodejs
npm install -g "pnpm@$(pin PNPM_VERSION 9.15.9)"

if [ "$INSTALL_DOCKER" = "true" ]; then
  log "installing Docker"
  mkdir -p /etc/docker
  if [ ! -f /etc/docker/daemon.json ]; then
    cat > /etc/docker/daemon.json <<'EOF'
{
  "no-new-privileges": true
}
EOF
  fi
  DOCKER_VER=$(pin DOCKER_VERSION "")
  if [ -n "$DOCKER_VER" ] && [ "$DOCKER_VER" != "latest" ]; then
    env -u TAILSCALE_AUTHKEY -u PROVISIONING_TOKEN VERSION="$DOCKER_VER" sh -c 'curl -fsSL https://get.docker.com | sh' || log "warning: docker installation failed (continuing)"
  else
    env -u TAILSCALE_AUTHKEY -u PROVISIONING_TOKEN sh -c 'curl -fsSL https://get.docker.com | sh' || log "warning: docker installation failed (continuing)"
  fi
  usermod -aG docker "$DEVBOX_USER" 2>/dev/null || true
  systemctl enable --now docker 2>/dev/null || true
fi

log "installing Tailscale"
if curl -fsSL https://tailscale.com/install.sh | sh; then
  TS_VER=$(pin TAILSCALE_VERSION "")
  if [ -n "$TS_VER" ] && [ "$TS_VER" != "latest" ]; then
    apt-get install -y --allow-downgrades "tailscale=$TS_VER" 2>/dev/null || true
  fi
  if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
    touch /etc/devbox/.tailscale_requested
    log "joining Tailscale network"
    if ! tailscale up --authkey="${TAILSCALE_AUTHKEY}" --hostname="agent-devbox"; then
      log "WARNING: Tailscale join failed (check auth key)"
      touch /etc/devbox/.failed_tailscale
    else
      # Allow unprivileged dev user to manage tailscale serve without sudo (WP-3D)
      tailscale set --operator="$DEVBOX_USER" 2>/dev/null || true
    fi
  fi
else
  log "WARNING: tailscale install script failed (continuing)"
  if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
    touch /etc/devbox/.failed_tailscale
  fi
fi
# Scrub sensitive auth key from disk immediately after joining
sed -i '/^TAILSCALE_AUTHKEY=/d' /etc/devbox/devbox.env 2>/dev/null || true
unset TAILSCALE_AUTHKEY

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
ClientAliveInterval 30
ClientAliveCountMax 120
TCPKeepAlive yes
EOF
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true

log "base install done"
