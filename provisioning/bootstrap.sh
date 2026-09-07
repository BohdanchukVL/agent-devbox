#!/usr/bin/env bash
# Agent Devbox thin bootstrap runner
# Fetches the repository payload, stages scripts in /opt/devbox, and executes installers.

set -euo pipefail

log() { echo "[$(date -u +'%Y-%m-%d %H:%M:%S UTC')] $*"; }

err_report() {
  local exit_code="$1"
  local cmd="$2"
  local line="$3"
  echo "Bootstrap failed at line $line (command: '$cmd', exit code: $exit_code)" > /etc/devbox/.failed
  echo "[bootstrap ERROR] Command '$cmd' failed at line $line with exit code $exit_code" >&2
}
trap 'err_report $? "$BASH_COMMAND" "$LINENO"' ERR

if [ -f /etc/devbox/devbox.env ]; then
  # shellcheck source=/dev/null
  . /etc/devbox/devbox.env
fi

DEVBOX_USER="${DEVBOX_USER:-dev}"
PROVISIONING_REPO="${PROVISIONING_REPO:-}"
PROVISIONING_REF="${PROVISIONING_REF:-main}"
PROVISIONING_TOKEN="${PROVISIONING_TOKEN:-}"
PROVISIONING_SHA256="${PROVISIONING_SHA256:-}"
PROVISIONING_TARBALL_URL="${PROVISIONING_TARBALL_URL:-}"

mkdir -p /opt/devbox /etc/devbox

# Download & unpack repository if scripts not already staged
if [ ! -f /opt/devbox/install-base.sh ] && [ ! -f /opt/devbox/provisioning/install-base.sh ]; then
  log "Downloading agent-devbox provisioning payload..."
  PAYLOAD_TAR="/tmp/devbox-payload.tar.gz"

  if [ -n "$PROVISIONING_TARBALL_URL" ]; then
    log "Fetching payload from $PROVISIONING_TARBALL_URL"
    if [ -n "$PROVISIONING_TOKEN" ]; then
      curl -fsSL --retry 3 --retry-delay 2 -H "Authorization: Bearer $PROVISIONING_TOKEN" "$PROVISIONING_TARBALL_URL" -o "$PAYLOAD_TAR"
    else
      curl -fsSL --retry 3 --retry-delay 2 "$PROVISIONING_TARBALL_URL" -o "$PAYLOAD_TAR"
    fi
  elif [ -n "$PROVISIONING_REPO" ] && [ -n "$PROVISIONING_REF" ]; then
    log "Fetching payload from GitHub: $PROVISIONING_REPO @ $PROVISIONING_REF"
    if [ -n "$PROVISIONING_TOKEN" ]; then
      curl -fsSL --retry 3 --retry-delay 2 \
        -H "Authorization: Bearer $PROVISIONING_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${PROVISIONING_REPO}/tarball/${PROVISIONING_REF}" \
        -o "$PAYLOAD_TAR"
    else
      curl -fsSL --retry 3 --retry-delay 2 \
        "https://github.com/${PROVISIONING_REPO}/archive/${PROVISIONING_REF}.tar.gz" \
        -o "$PAYLOAD_TAR"
    fi
  else
    echo "Error: No provisioning repository or tarball URL specified." >&2
    exit 1
  fi

  if [ -n "$PROVISIONING_SHA256" ]; then
    log "Verifying payload checksum..."
    echo "$PROVISIONING_SHA256  $PAYLOAD_TAR" | sha256sum -c -
  fi

  log "Extracting payload to /opt/devbox..."
  tar -xzf "$PAYLOAD_TAR" --strip-components=1 -C /opt/devbox
  rm -f "$PAYLOAD_TAR"
fi

# Scrub sensitive GitHub token if it was provided
if [ -f /etc/devbox/devbox.env ] && grep -q '^PROVISIONING_TOKEN=' /etc/devbox/devbox.env; then
  sed -i '/^PROVISIONING_TOKEN=/d' /etc/devbox/devbox.env 2>/dev/null || true
fi
unset PROVISIONING_TOKEN TAILSCALE_AUTHKEY

# Create symlinks in /opt/devbox for files under /opt/devbox/provisioning
if [ -d /opt/devbox/provisioning ]; then
  for f in /opt/devbox/provisioning/*; do
    bn=$(basename "$f")
    [ ! -e "/opt/devbox/$bn" ] && ln -s "$f" "/opt/devbox/$bn"
  done
fi

chmod +x /opt/devbox/*.sh /opt/devbox/provisioning/*.sh 2>/dev/null || true

# Install MOTD, tmux config, and prompt hooks
if [ -f /opt/devbox/motd.sh ]; then
  install -m 0755 /opt/devbox/motd.sh /etc/update-motd.d/99-devbox
fi

if [ -f /opt/devbox/tmux.conf ]; then
  install -m 0644 -o "$DEVBOX_USER" -g "$DEVBOX_USER" /opt/devbox/tmux.conf "/home/$DEVBOX_USER/.tmux.conf"
fi

if [ -f /opt/devbox/tmux-status.sh ]; then
  install -D -m 0755 -o "$DEVBOX_USER" -g "$DEVBOX_USER" /opt/devbox/tmux-status.sh "/home/$DEVBOX_USER/.devbox/bin/tmux-status"
fi

if [ -f /opt/devbox/osc7.sh ]; then
  grep -q devbox-osc7 /etc/bash.bashrc || echo '[ -f /opt/devbox/osc7.sh ] && . /opt/devbox/osc7.sh # devbox-osc7' >> /etc/bash.bashrc
fi

chmod -x /etc/update-motd.d/10-help-text /etc/update-motd.d/50-motd-news 2>/dev/null || true

# Execute installers
log "Executing install-base.sh..."
/opt/devbox/install-base.sh

log "Executing install-agents.sh..."
/opt/devbox/install-agents.sh

if [ "${INSTALL_BROWSER:-true}" = "true" ] && [ -x /opt/devbox/install-browser.sh ]; then
  log "Executing install-browser.sh..."
  /opt/devbox/install-browser.sh
fi

log "Executing install-shell.sh..."
/opt/devbox/install-shell.sh

rm -f /etc/devbox/.failed
touch /etc/devbox/.provisioned
log "Agent devbox provisioning finished successfully."
