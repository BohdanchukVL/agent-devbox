#!/usr/bin/env bash
# Login banner (installed as /etc/update-motd.d/99-devbox).
# Reports live status so it stays truthful even mid-provisioning.

# agents live in the dev user's npm prefix, not on root's PATH — look there too
. /etc/devbox/devbox.env 2>/dev/null || true
DEV_BIN="/home/${DEVBOX_USER:-dev}/.npm-global/bin"
have() { command -v "$1" >/dev/null 2>&1 || [ -x "$DEV_BIN/$1" ]; }

if [ -e /etc/devbox/.provisioned ]; then
  docker_status="not installed"
  if have docker; then
    if docker info >/dev/null 2>&1 || systemctl is-active -q docker 2>/dev/null; then
      docker_status="ready"
    else
      docker_status="installed (not running)"
    fi
  fi
  codex_status=$(have codex && echo "installed" || echo "not installed")
  claude_status=$(have claude && echo "installed" || echo "not installed")
  browser_status=$(have playwright && echo "installed" || echo "not installed")
else
  docker_status="provisioning..."
  codex_status="provisioning..."
  claude_status="provisioning..."
  browser_status="provisioning..."
fi

line() { printf "│ %-40s │\n" "$1"; }

echo "┌──────────────────────────────────────────┐"
line "Agent Devbox"
line ""
line "Workspace: /workspace"
line "Docker: $docker_status"
line "Codex: $codex_status"
line "Claude Code: $claude_status"
line "Browser: $browser_status"
line ""
line "Next steps:"
line "  gh auth login"
line "  git config --global user.name ..."
line "  git config --global user.email ..."
line "  codex login --device-auth"
line "  claude"
if [ ! -e /etc/devbox/.provisioned ]; then
  line ""
  line "Provisioning still running:"
  line "  tail -f /var/log/devbox-install.log"
fi
echo "└──────────────────────────────────────────┘"
