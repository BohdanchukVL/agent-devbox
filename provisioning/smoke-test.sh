#!/usr/bin/env bash
# Agent Devbox readiness & smoke test suite.
# Verifies that all provisioned services, CLI tools, MCP servers,
# and web companions are fully functional and ready for pair programming.
set -euo pipefail

PASS=0
FAIL=0

ok() {
  echo "  [PASS] $*"
  PASS=$((PASS + 1))
}

fail() {
  echo "  [FAIL] $*" >&2
  FAIL=$((FAIL + 1))
}

warn() {
  echo "  [WARN] $*"
}

echo "=== Agent Devbox Readiness & Smoke Tests ==="

# 1. Provisioning completion check
if [ -f /etc/devbox/.failed ]; then
  fail "Provisioning failed flag /etc/devbox/.failed is present: $(cat /etc/devbox/.failed 2>/dev/null || true)"
else
  ok "No /etc/devbox/.failed flag found"
fi

if [ -f /etc/devbox/.provisioned ]; then
  ok "Provisioning status is completed (/etc/devbox/.provisioned)"
else
  warn "/etc/devbox/.provisioned not yet created (running during bootstrap)"
fi

# Load configuration flags if available
if [ -f /etc/devbox/devbox.env ]; then
  # shellcheck source=/dev/null
  . /etc/devbox/devbox.env
fi

DEVBOX_USER="${DEVBOX_USER:-dev}"
HOME_DIR="/home/$DEVBOX_USER"
export PATH="$HOME_DIR/.npm-global/bin:$HOME_DIR/.local/bin:/usr/local/bin:$PATH"

# 2. Base toolchain verification
for bin in git curl jq tmux rg fzf node; do
  if command -v "$bin" >/dev/null 2>&1; then
    ok "Core binary available: $bin ($("$bin" --version 2>&1 | head -n 1))"
  else
    fail "Missing core binary: $bin"
  fi
done

# 3. Workspace storage verification
if [ -d /workspace ]; then
  if [ -w /workspace ]; then
    ok "Workspace directory /workspace is writable"
  else
    fail "Workspace directory /workspace exists but is not writable"
  fi
else
  warn "/workspace does not exist; using user home"
fi

# 4. Agent verification (based on configured flags)
if [ "${INSTALL_CODEX:-true}" = "true" ]; then
  if sudo -u "$DEVBOX_USER" -H bash -c 'export PATH="$HOME/.npm-global/bin:$PATH"; command -v codex >/dev/null 2>&1'; then
    CODEX_VER=$(sudo -u "$DEVBOX_USER" -H bash -c 'export PATH="$HOME/.npm-global/bin:$PATH"; codex --version 2>&1 | head -n1' || true)
    ok "Codex CLI is installed ($CODEX_VER)"
  else
    fail "Codex CLI is enabled but not found on PATH for user $DEVBOX_USER"
  fi
fi

if [ "${INSTALL_CLAUDE:-true}" = "true" ]; then
  if sudo -u "$DEVBOX_USER" -H bash -c 'export PATH="$HOME/.npm-global/bin:$PATH"; command -v claude >/dev/null 2>&1'; then
    CLAUDE_VER=$(sudo -u "$DEVBOX_USER" -H bash -c 'export PATH="$HOME/.npm-global/bin:$PATH"; claude --version 2>&1 | head -n1' || true)
    ok "Claude Code is installed ($CLAUDE_VER)"
  else
    fail "Claude Code is enabled but not found on PATH for user $DEVBOX_USER"
  fi
fi

if [ "${INSTALL_ANTIGRAVITY:-true}" = "true" ]; then
  if [ -x "$HOME_DIR/.local/bin/agy" ] || command -v agy >/dev/null 2>&1; then
    AGY_VER=$(sudo -u "$DEVBOX_USER" -H bash -c 'export PATH="$HOME/.local/bin:$PATH"; agy --version 2>&1 | head -n1' || true)
    ok "Antigravity CLI (agy) is installed ($AGY_VER)"
  else
    warn "Antigravity CLI (agy) binary not found"
  fi
fi

# 4b. Claude statusLine hook (feeds the tmux status bar)
if [ "${INSTALL_CLAUDE:-true}" = "true" ]; then
  if [ -x "$HOME_DIR/.devbox/bin/claude-statusline" ]; then
    ok "Claude statusLine hook installed ($HOME_DIR/.devbox/bin/claude-statusline)"
  else
    fail "Claude statusLine hook missing at $HOME_DIR/.devbox/bin/claude-statusline"
  fi
  if jq -e --arg cmd "$HOME_DIR/.devbox/bin/claude-statusline" '.statusLine.command == $cmd' "$HOME_DIR/.claude/settings.json" >/dev/null 2>&1; then
    ok "Claude settings.json statusLine points at the devbox hook"
  else
    warn "Claude settings.json statusLine is not configured for the devbox hook"
  fi
fi

# 5. Docker daemon verification
if [ "${INSTALL_DOCKER:-true}" = "true" ]; then
  if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
      ok "Docker daemon is running and responsive"
    else
      fail "Docker is installed but daemon is not responsive"
    fi
  else
    fail "Docker was requested but 'docker' command is missing"
  fi
fi

# 6. Web companion gateway verification
if [ -d "$HOME_DIR/.devbox/web" ]; then
  # Check if gateway responds on localhost:7681
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:7681/api/status 2>/dev/null || echo "000")
  if [ "$HTTP_STATUS" = "200" ]; then
    ok "devbox-web companion gateway is running and responding (HTTP 200 on port 7681)"
  else
    # Check if systemd unit exists
    if systemctl --user -M "$DEVBOX_USER@" is-active devbox-web.service >/dev/null 2>&1; then
      ok "devbox-web.service is active (HTTP status: $HTTP_STATUS)"
    else
      warn "devbox-web gateway not responding on 7681 (status: $HTTP_STATUS)"
    fi
  fi
fi

# 7. Headless browser verification
if [ "${INSTALL_BROWSER:-true}" = "true" ]; then
  if command -v chromium >/dev/null 2>&1 || command -v google-chrome >/dev/null 2>&1 || [ -d "$HOME_DIR/.cache/ms-playwright" ]; then
    ok "Headless browser binaries available"
  else
    warn "Playwright/Chromium browser cache not yet detected"
  fi
fi

# 8. Summary
echo "==========================================="
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Smoke test verification FAILED." >&2
  exit 1
fi
echo "All smoke tests PASSED. Devbox is fully operational."
exit 0
