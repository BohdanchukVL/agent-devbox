#!/usr/bin/env bash
# AI coding agents, installed into a USER-OWNED npm prefix so the dev user can
# self-update them — root-owned globals break `claude`/`codex` auto-update
# ("no write permission to npm prefix"). Runs once as root via cloud-init after
# install-base.sh; flags come from /etc/devbox/devbox.env. Idempotent.
set -euo pipefail
trap 'touch /etc/devbox/.failed 2>/dev/null || true' ERR

# shellcheck source=/dev/null
. /etc/devbox/devbox.env
# shellcheck source=/dev/null
. /opt/devbox/versions.env 2>/dev/null || . /opt/devbox/provisioning/versions.env 2>/dev/null || true
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

pin() {
  local var_name="$1"
  local fallback="${2:-latest}"
  if [ "${DEVBOX_RELEASE_CHANNEL:-stable}" = "stable" ]; then
    echo "${!var_name:-$fallback}"
  else
    echo "latest"
  fi
}

# install as dev so files land in the dev-owned prefix (npm reads ~/.npmrc)
agent() {
  log "installing npm package(s): $*"
  sudo -u "$U" -H npm install -g "$@" || log "warning: failed to install: $* (continuing)"
}

if [ "$INSTALL_CODEX" = "true" ]; then
  log "installing Codex CLI"
  which bwrap >/dev/null 2>&1 || apt-get install -y --no-install-recommends bubblewrap || true
  agent "@openai/codex@$(pin CODEX_VERSION latest)"
fi

if [ "$INSTALL_CLAUDE" = "true" ]; then
  log "installing Claude Code"
  agent "@anthropic-ai/claude-code@$(pin CLAUDE_CODE_VERSION latest)"
fi

if [ "$INSTALL_CLAUDE" = "true" ] || [ "$INSTALL_CODEX" = "true" ]; then
  log "installing ccusage session limit tracker"
  agent "ccusage@$(pin CCUSAGE_VERSION 20.0.20)"
fi

if [ "$INSTALL_OPENCODE" = "true" ]; then
  log "installing OpenCode"
  agent "opencode-ai@$(pin OPENCODE_VERSION latest)"
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
agent "@ast-grep/cli@$(pin AST_GREP_VERSION 0.38.1)" \
  "@notprolands/ast-grep-mcp@$(pin AST_GREP_MCP_VERSION 0.1.7)" \
  "@modelcontextprotocol/server-memory@$(pin MCP_MEMORY_VERSION 0.6.2)" \
  "@playwright/mcp@$(pin PLAYWRIGHT_MCP_VERSION 0.0.32)"

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

# Install per-project memory wrapper (routes memory to <git-root>/.devbox/memory.jsonl)
if [ -f /opt/devbox/devbox-memory.sh ] || [ -f /opt/devbox/provisioning/devbox-memory.sh ]; then
  MEMORY_SRC=$([ -f /opt/devbox/devbox-memory.sh ] && echo /opt/devbox/devbox-memory.sh || echo /opt/devbox/provisioning/devbox-memory.sh)
  install -D -m 0755 -o "$U" -g "$U" "$MEMORY_SRC" "$H/.devbox/bin/devbox-memory"
fi

# Add .devbox/ to global git excludes so per-project memory files are never committed
sudo -u "$U" -H bash -c '
  EXCLUDES="$HOME/.config/git/ignore"
  mkdir -p "$(dirname "$EXCLUDES")"
  touch "$EXCLUDES"
  grep -qxF ".devbox/" "$EXCLUDES" 2>/dev/null || echo ".devbox/" >> "$EXCLUDES"
  git config --global core.excludesfile "$EXCLUDES"
' || true

# Pre-configure MCP servers for Claude Code
if command -v claude >/dev/null 2>&1 || [ -x "$PREFIX/bin/claude" ]; then
  sudo -u "$U" -H bash -c "export PATH=\"$PREFIX/bin:\$PATH\"; claude mcp add -s user ast-grep -- ast-grep-mcp 2>/dev/null || true"
  sudo -u "$U" -H bash -c "export PATH=\"$PREFIX/bin:\$PATH\"; claude mcp add -s user code-intel -- '$H/.devbox/mcp/code-intel/index.js' 2>/dev/null || true"
  sudo -u "$U" -H bash -c "export PATH=\"$PREFIX/bin:\$PATH\"; claude mcp add -s user memory -- '$H/.devbox/bin/devbox-memory' 2>/dev/null || true"
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

# Configure Claude Code statusLine hook (provisioning/claude-statusline.sh): it
# persists the session JSON per session for the tmux status bar and prints
# Claude Code's own status row. refreshInterval keeps rate-limit windows and
# idle sessions current (seconds).
STATUSLINE_BIN="$H/.devbox/bin/claude-statusline"
install -d -o "$U" -g "$U" "$H/.claude"
# Configure Claude Code settings (statusLine hook + strict sandbox WP-3B via jq merge)
STRICT_SANDBOX="${AGENT_SANDBOX_STRICT:-true}"
ALLOWED_DOMAINS='["registry.npmjs.org","github.com","api.github.com","objects.githubusercontent.com","crates.io","static.crates.io","pypi.org","files.pythonhosted.org","proxy.golang.org"]'

SETTINGS_FILE="$H/.claude/settings.json"
if [ ! -f "$SETTINGS_FILE" ] || ! jq -e . "$SETTINGS_FILE" >/dev/null 2>&1; then
  echo "{}" > "$SETTINGS_FILE"
fi

TMP_SETTINGS=$(mktemp)
jq --arg cmd "$STATUSLINE_BIN" \
   --argjson strict "$([ "$STRICT_SANDBOX" = "false" ] && echo "false" || echo "true")" \
   --argjson domains "$ALLOWED_DOMAINS" \
   'del(.allowUnsandboxedCommands) |
    .statusLine = {"type": "command", "command": $cmd, "refreshInterval": 30} |
    .sandbox = {
      "enabled": true,
      "failIfUnavailable": true,
      "credentials": {
        "files": [
          {"path": "~/.aws", "mode": "deny"},
          {"path": "~/.ssh", "mode": "deny"},
          {"path": "~/.config/gh", "mode": "deny"}
        ],
        "envVars": [
          {"name": "AWS_ACCESS_KEY_ID", "mode": "deny"},
          {"name": "AWS_SECRET_ACCESS_KEY", "mode": "deny"},
          {"name": "AWS_SESSION_TOKEN", "mode": "deny"},
          {"name": "GITHUB_TOKEN", "mode": "deny"},
          {"name": "GH_TOKEN", "mode": "deny"}
        ]
      },
      "network": {
        "allowedDomains": $domains
      }
    } |
    if $strict then .sandbox.allowUnsandboxedCommands = false else del(.sandbox.allowUnsandboxedCommands) end' \
   "$SETTINGS_FILE" > "$TMP_SETTINGS" && mv "$TMP_SETTINGS" "$SETTINGS_FILE"

chown "$U:$U" "$SETTINGS_FILE"
chmod 0600 "$SETTINGS_FILE"
rm -f /tmp/.claude-status.json 2>/dev/null || true

# Codex sandbox config (WP-3B: workspace-write sandbox mode)
install -d -o "$U" -g "$U" "$H/.codex"
cat > "$H/.codex/config.toml" <<'TOML'
# Codex configuration for agent-devbox
sandbox_mode = "workspace-write"
approval_policy = "on-request"

[sandbox_workspace_write]
writable_roots = ["/workspace"]
network_access = true
TOML
chown "$U:$U" "$H/.codex/config.toml"
chmod 0600 "$H/.codex/config.toml"

# Configure persistent memory storage (persisting across VM rebuilds if /workspace is mounted)
if mountpoint -q /workspace 2>/dev/null; then
  MEMORY_DIR="/workspace/.devbox"
else
  MEMORY_DIR="$H/.devbox"
fi
install -d -o "$U" -g "$U" "$MEMORY_DIR" "$H/.devbox"
MEMORY_PATH="$MEMORY_DIR/memory.jsonl"
touch "$MEMORY_PATH"
chown "$U:$U" "$MEMORY_PATH"
chmod 0600 "$MEMORY_PATH"
if [ "$MEMORY_DIR" != "$H/.devbox" ]; then
  ln -sf "$MEMORY_PATH" "$H/.devbox/memory.jsonl" 2>/dev/null || true
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
      "command": "$H/.devbox/bin/devbox-memory",
      "args": []
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

  # Auth mode: tailnet identity when this machine joined the tailnet (no token),
  # shared token otherwise. Override with DEVBOX_WEB_AUTH=token|tailscale.
  WEB_AUTH="${DEVBOX_WEB_AUTH:-}"
  if [ -z "$WEB_AUTH" ]; then
    if command -v tailscale >/dev/null 2>&1 && [ "$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty')" = "Running" ]; then
      WEB_AUTH=tailscale
    else
      WEB_AUTH=token
    fi
  fi

  WEB_READY=1
  if [ "$WEB_AUTH" = "tailscale" ]; then
    printf 'DEVBOX_WEB_AUTH=tailscale\nHOST=auto\n' > "$H/.devbox/web.env"
    log "devbox-web: tailnet identity auth, no token"
  else
    # Shared token (guaranteed non-empty, fail-closed)
    TOKEN="${DEVBOX_WEB_TOKEN:-}"
    if [ -z "$TOKEN" ]; then
      TOKEN=$(openssl rand -hex 16 2>/dev/null || od -vN 16 -An -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    fi
    if [ -z "$TOKEN" ]; then
      log "warning: failed to generate secure DEVBOX_WEB_TOKEN; skipping devbox-web setup"
      WEB_READY=0
    else
      printf 'DEVBOX_WEB_AUTH=token\nDEVBOX_WEB_TOKEN=%s\n' "$TOKEN" > "$H/.devbox/web.env"
      log "devbox-web: token auth, token in ~/.devbox/web.env"
    fi
  fi

  if [ "$WEB_READY" = 1 ]; then
    chmod 0600 "$H/.devbox/web.env"
    chown "$U:$U" "$H/.devbox/web.env"

    # URL helper used by the MOTD, the deploy summary and `devbox web`
    if [ -f /opt/devbox/devbox-web-url.sh ] || [ -f /opt/devbox/provisioning/devbox-web-url.sh ]; then
      WEB_URL_SRC=$([ -f /opt/devbox/devbox-web-url.sh ] && echo /opt/devbox/devbox-web-url.sh || echo /opt/devbox/provisioning/devbox-web-url.sh)
      install -D -m 0755 -o "$U" -g "$U" "$WEB_URL_SRC" "$H/.devbox/bin/devbox-web-url"
    fi

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

  fi
fi

log "agent install done"
