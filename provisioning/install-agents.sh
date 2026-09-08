#!/usr/bin/env bash
# AI coding agents, installed into a USER-OWNED npm prefix so the dev user can
# self-update them — root-owned globals break `claude`/`codex` auto-update
# ("no write permission to npm prefix"). Runs once as root via cloud-init after
# install-base.sh; flags come from /etc/devbox/devbox.env. Idempotent.
set -euo pipefail
trap 'touch /etc/devbox/.failed 2>/dev/null || true' ERR

# shellcheck source=/dev/null
. /etc/devbox/devbox.env
U="$DEVBOX_USER"
H="/home/$U"
PREFIX="$H/.npm-global"

log() { echo "[devbox $(date -u +%H:%M:%S)] $*"; }

# per-user global prefix owned by dev → agents write their own updates
install -d -o "$U" -g "$U" "$PREFIX"
sudo -u "$U" -H npm config set prefix "$PREFIX"
# Set global PATH for devbox user binaries in login shells
# shellcheck disable=SC2016
echo 'export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"' > /etc/profile.d/devbox-npm.sh
chmod 0644 /etc/profile.d/devbox-npm.sh
# put the prefix on PATH for non-interactive zsh sessions (e.g. ssh dev@host claude ...)
install -m 0644 -o "$U" -g "$U" /dev/null "$H/.zshenv"
# shellcheck disable=SC2016
echo 'export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"' >> "$H/.zshenv"

# install as dev so files land in the dev-owned prefix (npm reads ~/.npmrc)
agent() {
  log "installing npm package(s): $*"
  sudo -u "$U" -H npm install -g "$@" || log "warning: failed to install: $* (continuing)"
}

if [ "$INSTALL_CODEX" = "true" ]; then
  log "installing Codex CLI"
  which bwrap >/dev/null 2>&1 || apt-get install -y --no-install-recommends bubblewrap || true
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
  install -d -o "$U" -g "$U" "$H/.local/bin"
  # standalone Go binary → ~/.local/bin/agy (not npm); tolerate a failed fetch
  sudo -u "$U" -H bash -c 'export PATH="$HOME/.local/bin:$PATH"; curl -fsSL https://antigravity.google/cli/install.sh | bash' \
    || log "antigravity install failed (skipping)"
  [ -f "$H/.local/bin/agy" ] && ln -sf "$H/.local/bin/agy" /usr/local/bin/agy || true
fi

log "installing code intelligence and MCP tools"
agent @ast-grep/cli @notprolands/ast-grep-mcp @modelcontextprotocol/server-memory @playwright/mcp

# Setup devbox-code-intel MCP server
install -d -o "$U" -g "$U" "$H/.devbox/mcp/code-intel"
if [ -d "/opt/devbox/mcp/code-intel" ]; then
  cp -r /opt/devbox/mcp/code-intel/* "$H/.devbox/mcp/code-intel/"
else
  log "warning: /opt/devbox/mcp/code-intel not found"
fi
chmod +x "$H/.devbox/mcp/code-intel/index.js" 2>/dev/null || true
chown -R "$U:$U" "$H/.devbox/mcp/code-intel"
sudo -u "$U" -H bash -c "cd '$H/.devbox/mcp/code-intel' && npm install --omit=dev" || true

# Setup devbox-db MCP server
install -d -o "$U" -g "$U" "$H/.devbox/mcp/db"
if [ -d "/opt/devbox/mcp/db" ]; then
  cp -r /opt/devbox/mcp/db/* "$H/.devbox/mcp/db/"
else
  log "warning: /opt/devbox/mcp/db not found"
fi
chmod +x "$H/.devbox/mcp/db/index.js" 2>/dev/null || true
chown -R "$U:$U" "$H/.devbox/mcp/db"
sudo -u "$U" -H bash -c "cd '$H/.devbox/mcp/db' && npm install --omit=dev" || true

# Pre-configure MCP servers for Claude Code
if command -v claude >/dev/null 2>&1 || [ -x "$PREFIX/bin/claude" ]; then
  sudo -u "$U" -H bash -c "export PATH=\"$PREFIX/bin:\$PATH\"; claude mcp add -s user ast-grep -- ast-grep-mcp 2>/dev/null || true"
  sudo -u "$U" -H bash -c "export PATH=\"$PREFIX/bin:\$PATH\"; claude mcp add -s user code-intel -- '$H/.devbox/mcp/code-intel/index.js' 2>/dev/null || true"
  sudo -u "$U" -H bash -c "export PATH=\"$PREFIX/bin:\$PATH\"; claude mcp add -s user memory -e MEMORY_FILE_PATH='$H/.devbox/memory.jsonl' -- mcp-server-memory 2>/dev/null || true"
  sudo -u "$U" -H bash -c "export PATH=\"$PREFIX/bin:\$PATH\"; claude mcp add -s user playwright -- playwright-mcp --headless 2>/dev/null || true"
  sudo -u "$U" -H bash -c "export PATH=\"$PREFIX/bin:\$PATH\"; claude mcp add -s user db -- '$H/.devbox/mcp/db/index.js' 2>/dev/null || true"
fi

# Setup guidelines for agents (user-level only to prevent prompt duplication and avoid polluting workspace)
install -d -o "$U" -g "$U" "$H/.claude" "$H/.gemini/config"
if [ -f "/opt/devbox/CLAUDE.md" ]; then
  install -m 0644 -o "$U" -g "$U" /opt/devbox/CLAUDE.md "$H/.claude/CLAUDE.md"
  install -m 0644 -o "$U" -g "$U" /opt/devbox/CLAUDE.md "$H/.gemini/config/AGENTS.md"
elif [ -f "/opt/devbox/provisioning/CLAUDE.md" ]; then
  install -m 0644 -o "$U" -g "$U" /opt/devbox/provisioning/CLAUDE.md "$H/.claude/CLAUDE.md"
  install -m 0644 -o "$U" -g "$U" /opt/devbox/provisioning/CLAUDE.md "$H/.gemini/config/AGENTS.md"
fi

# Configure Claude Code statusLine hook to export live rate limits to /tmp/.claude-status.json
if [ -f "$H/.claude/settings.json" ]; then
  sudo -u "$U" jq '.statusLine = {"type": "command", "command": "jq -c . > /tmp/.claude-status.json"}' "$H/.claude/settings.json" > "$H/.claude/settings.json.tmp" && mv "$H/.claude/settings.json.tmp" "$H/.claude/settings.json"
else
  cat > "$H/.claude/settings.json" <<EOF
{
  "statusLine": {
    "type": "command",
    "command": "jq -c . > /tmp/.claude-status.json"
  }
}
EOF
  chown "$U:$U" "$H/.claude/settings.json"
fi

# Pre-configure MCP for Antigravity
cat > "$H/.gemini/config/mcp_config.json" <<EOF
{
  "mcpServers": {
    "code-intel": {
      "command": "node",
      "args": ["$H/.devbox/mcp/code-intel/index.js"]
    },
    "ast-grep": {
      "command": "ast-grep-mcp",
      "args": []
    },
    "memory": {
      "command": "mcp-server-memory",
      "args": [],
      "env": {
        "MEMORY_FILE_PATH": "$H/.devbox/memory.jsonl"
      }
    },
    "playwright": {
      "command": "playwright-mcp",
      "args": ["--headless"]
    },
    "db": {
      "command": "node",
      "args": ["$H/.devbox/mcp/db/index.js"]
    }
  }
}
EOF
chown -R "$U:$U" "$H/.gemini"

# Setup devbox-web companion gateway
if [ -d "/opt/devbox/web" ]; then
  log "installing devbox-web gateway..."
  WEB_DIR="$H/.devbox/web"
  mkdir -p "$WEB_DIR"
  cp -r /opt/devbox/web/* "$WEB_DIR/"
  chown -R "$U:$U" "$WEB_DIR"

  # Generate or configure web gateway token (guaranteed non-empty, fail-closed)
  TOKEN="${DEVBOX_WEB_TOKEN:-}"
  if [ -z "$TOKEN" ]; then
    TOKEN=$(openssl rand -hex 16 2>/dev/null || od -vN 16 -An -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  fi
  if [ -z "$TOKEN" ]; then
    log "warning: failed to generate secure DEVBOX_WEB_TOKEN; skipping devbox-web setup"
  else
    echo "DEVBOX_WEB_TOKEN=$TOKEN" > "$H/.devbox/web.env"
    chmod 0600 "$H/.devbox/web.env"
    chown "$U:$U" "$H/.devbox/web.env"

    # Install web gateway dependencies
    sudo -u "$U" -H bash -c "cd '$WEB_DIR' && (npm ci --omit=dev 2>/dev/null || npm install --omit=dev)" || true

    # Setup systemd user service
    SYSTEMD_USER_DIR="$H/.config/systemd/user"
    install -d -o "$U" -g "$U" "$SYSTEMD_USER_DIR"
    if [ -f "$WEB_DIR/devbox-web.service" ]; then
      install -m 0644 -o "$U" -g "$U" "$WEB_DIR/devbox-web.service" "$SYSTEMD_USER_DIR/devbox-web.service"
      loginctl enable-linger "$U" 2>/dev/null || true
      U_UID=$(id -u "$U")
      systemctl start "user@$U_UID.service" 2>/dev/null || true
      for _ in 1 2 3 4 5; do
        [ -S "/run/user/$U_UID/bus" ] || [ -S "/run/user/$U_UID/systemd/private" ] && break
        sleep 0.5
      done
      systemctl --user -M "$U@" daemon-reload 2>/dev/null || true
      systemctl --user -M "$U@" enable --now devbox-web.service 2>/dev/null || true
    fi

    # If Tailscale is running, expose port 7681 securely with MagicDNS HTTPS inside Tailnet
    if command -v tailscale >/dev/null 2>&1 && tailscale ip -4 >/dev/null 2>&1; then
      log "configuring tailscale serve for devbox-web (port 7681)..."
      timeout 5 tailscale serve --bg 7681 2>/dev/null || true
    fi
  fi
fi

log "agent install done"
