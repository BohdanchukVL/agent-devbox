#!/usr/bin/env bash
# AI coding agents, installed into a USER-OWNED npm prefix so the dev user can
# self-update them — root-owned globals break `claude`/`codex` auto-update
# ("no write permission to npm prefix"). Runs once as root via cloud-init after
# install-base.sh; flags come from /etc/devbox/devbox.env. Idempotent.
set -euo pipefail
trap 'touch /etc/devbox/.failed 2>/dev/null || true' ERR

. /etc/devbox/devbox.env
U="$DEVBOX_USER"
H="/home/$U"
PREFIX="$H/.npm-global"

log() { echo "[devbox $(date -u +%H:%M:%S)] $*"; }

# per-user global prefix owned by dev → agents write their own updates
install -d -o "$U" -g "$U" "$PREFIX"
sudo -u "$U" -H npm config set prefix "$PREFIX"
# put the prefix on PATH for login bash/zsh + tmux panes
echo 'export PATH="$HOME/.npm-global/bin:$PATH"' > /etc/profile.d/devbox-npm.sh
chmod 0644 /etc/profile.d/devbox-npm.sh
# put the prefix on PATH for non-interactive zsh sessions (e.g. ssh dev@host claude ...)
install -m 0644 -o "$U" -g "$U" /dev/null "$H/.zshenv"
echo 'export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"' >> "$H/.zshenv"

# install as dev so files land in the dev-owned prefix (npm reads ~/.npmrc)
agent() { sudo -u "$U" -H npm install -g "$1"; }

if [ "$INSTALL_CODEX" = "true" ]; then
  log "installing Codex CLI"
  agent @openai/codex
fi

if [ "$INSTALL_CLAUDE" = "true" ]; then
  log "installing Claude Code"
  agent @anthropic-ai/claude-code
fi

if [ "$INSTALL_OPENCODE" = "true" ]; then
  log "installing OpenCode"
  agent opencode-ai
fi

if [ "${INSTALL_ANTIGRAVITY:-false}" = "true" ]; then
  log "installing Antigravity CLI (agy)"
  # standalone Go binary → ~/.local/bin/agy (not npm); tolerate a failed fetch
  sudo -u "$U" -H bash -c 'curl -fsSL https://antigravity.google/cli/install.sh | bash' \
    || log "antigravity install failed (skipping)"
fi

log "agent install done"
