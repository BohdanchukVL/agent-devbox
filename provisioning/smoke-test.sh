#!/usr/bin/env bash
# Agent Devbox readiness & smoke test suite.
# Verifies that all provisioned services, CLI tools, MCP servers,
# and web companions are fully functional and ready for pair programming.
set -euo pipefail

if [ "${1:-}" = "--manifest" ]; then
  if [ -f /etc/devbox/manifest.json ]; then
    cat /etc/devbox/manifest.json
    exit 0
  else
    echo "Manifest /etc/devbox/manifest.json not found." >&2
    exit 1
  fi
fi

PASS=0
FAIL=0
STRICT=0
SHOW_MANIFEST=0

for arg in "$@"; do
  case "$arg" in
    --strict)
      STRICT=1
      ;;
    --manifest)
      SHOW_MANIFEST=1
      ;;
  esac
done

if [ "$SHOW_MANIFEST" -eq 1 ]; then
  if [ -f /etc/devbox/manifest.json ]; then
    cat /etc/devbox/manifest.json
    exit 0
  else
    echo "Manifest /etc/devbox/manifest.json not found" >&2
    exit 1
  fi
fi

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
  if [ "$STRICT" -eq 1 ]; then
    FAIL=$((FAIL + 1))
  fi
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

# 8. Hardening integrity checks (F-09, WP-3C)
echo ""
echo "--- Hardening & Integrity checks ---"

# sudoers: user should have passwordless sudo and valid syntax
if sudo -n -u "$DEVBOX_USER" sudo -n true 2>/dev/null; then
  ok "Passwordless sudo works for $DEVBOX_USER"
else
  fail "Passwordless sudo not confirmed for $DEVBOX_USER"
fi

if [ -f /etc/sudoers.d/90-devbox ]; then
  if visudo -cf /etc/sudoers.d/90-devbox >/dev/null 2>&1; then
    ok "Sudoers drop-in /etc/sudoers.d/90-devbox syntax valid"
  else
    fail "Sudoers drop-in /etc/sudoers.d/90-devbox syntax invalid"
  fi
fi

# sshd: password auth should be disabled
SSHD_PASSAUTH=$(sshd -T 2>/dev/null | grep -i 'passwordauthentication' | awk '{print $2}')
if [ "$SSHD_PASSAUTH" = "no" ]; then
  ok "sshd PasswordAuthentication is disabled"
else
  fail "sshd PasswordAuthentication is not disabled (value: ${SSHD_PASSAUTH:-unknown})"
fi

# metadata guard service: systemd active check
if systemctl is-active --quiet devbox-metadata-guard.service 2>/dev/null; then
  ok "devbox-metadata-guard.service is active"
else
  fail "devbox-metadata-guard.service is not active"
fi

# metadata guard: iptables OUTPUT rule for 169.254.169.254
if iptables -C OUTPUT -m owner ! --uid-owner 0 -d 169.254.169.254 -j DROP 2>/dev/null; then
  ok "Metadata guard (IPv4 OUTPUT) active"
elif iptables -C OUTPUT -d 169.254.169.254 -j DROP 2>/dev/null; then
  ok "Metadata guard (IPv4 OUTPUT) active"
else
  fail "Metadata guard (IPv4 OUTPUT) not detected"
fi

# metadata guard: iptables DOCKER-USER rule
if iptables -L DOCKER-USER >/dev/null 2>&1; then
  if iptables -C DOCKER-USER -d 169.254.169.254 -j DROP 2>/dev/null; then
    ok "Metadata guard (DOCKER-USER) active"
  else
    fail "Metadata guard (DOCKER-USER) not detected"
  fi
fi

# system integrity check via sha256 manifest (WP-3C)
if [ -f /etc/devbox/integrity.sha256 ]; then
  if sha256sum -c --status /etc/devbox/integrity.sha256 2>/dev/null; then
    ok "System integrity hash matches baseline (/etc/devbox/integrity.sha256)"
  else
    fail "System integrity hash MISMATCH — critical security files modified!"
  fi
fi

# immutable attribute check (WP-3C)
if command -v lsattr >/dev/null 2>&1; then
  IMMUTABLE_OK=true
  for f in /etc/sudoers.d/90-devbox /etc/ssh/sshd_config.d/99-devbox.conf /usr/local/bin/devbox-doctor; do
    if [ -f "$f" ]; then
      if ! lsattr "$f" 2>/dev/null | cut -d' ' -f1 | grep -q 'i'; then
        IMMUTABLE_OK=false
        warn "File $f is not marked immutable (+i)"
      fi
    fi
  done
  if [ "$IMMUTABLE_OK" = "true" ]; then
    ok "Security configuration files marked immutable (+i)"
  fi
fi

# cloud-init scrub: no secrets in devbox.env
if [ -f /etc/devbox/devbox.env ]; then
  if grep -qE '(TAILSCALE_AUTHKEY|DEVBOX_WEB_TOKEN|PROVISIONING_TOKEN)=".+"' /etc/devbox/devbox.env 2>/dev/null; then
    fail "Secrets still present in /etc/devbox/devbox.env"
  else
    ok "Secrets scrubbed from /etc/devbox/devbox.env"
  fi
fi

# cloud-init instance cache: no secret leaks in obj.pkl
if [ -f /var/lib/cloud/instance/obj.pkl ]; then
  if (command -v strings >/dev/null 2>&1 && strings /var/lib/cloud/instance/obj.pkl 2>/dev/null || grep -a '' /var/lib/cloud/instance/obj.pkl 2>/dev/null) | grep -qiE '(tskey-[a-zA-Z0-9]+|DEVBOX_WEB_TOKEN)'; then
    fail "Secrets detected in cloud-init instance cache (/var/lib/cloud/instance/obj.pkl)"
  else
    ok "Cloud-init obj.pkl free of Tailscale authkeys or web tokens"
  fi
fi

# Bubblewrap unprivileged sandbox isolation check
if command -v bwrap >/dev/null 2>&1; then
  if bwrap --unshare-user --ro-bind / / -- sudo -n true 2>/dev/null; then
    fail "bwrap setuid privilege escalation succeeded (expected failure in unprivileged userns)"
  else
    ok "bwrap sandbox prevents setuid privilege escalation"
  fi
fi

# Docker metadata guard container egress check
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if docker run --rm curlimages/curl -s -m 2 http://169.254.169.254/ >/dev/null 2>&1; then
    fail "Docker container reached cloud metadata service (169.254.169.254)"
  else
    ok "Docker container blocked from cloud metadata endpoint (169.254.169.254)"
  fi
fi

# Tailscale connectivity & status check (WP-3A/WP-3D)
# When Tailscale auth key was supplied, verify that daemon is actually joined and Running
if [ -f /etc/devbox/.tailscale_requested ] || [ -f /etc/devbox/.failed_tailscale ] || [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
  if [ -f /etc/devbox/.failed_tailscale ]; then
    fail "Tailscale connection failed (/etc/devbox/.failed_tailscale is present)"
  elif command -v tailscale >/dev/null 2>&1; then
    TS_STATE=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' || true)
    if [ "$TS_STATE" = "Running" ]; then
      ok "Tailscale connected and operational (BackendState: Running)"
    else
      fail "Tailscale key was provided but backend is not Running (BackendState: ${TS_STATE:-Unknown})"
    fi
  else
    fail "Tailscale was requested but tailscale binary is missing"
  fi
fi

# Tailscale SSH check (RunSSH must be false to preserve native OpenSSH hardening)
if command -v tailscale >/dev/null 2>&1; then
  TS_STATE=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' || true)
  if [ "$TS_STATE" = "Running" ]; then
    TS_PREFS=$(tailscale debug prefs 2>/dev/null || true)
    if echo "$TS_PREFS" | grep -qiE 'RunSSH:.*true|"RunSSH":\s*true'; then
      fail "Tailscale SSH is enabled (RunSSH: true) — native OpenSSH required"
    elif echo "$TS_PREFS" | grep -qiE 'RunSSH:.*false|"RunSSH":\s*false'; then
      ok "Tailscale SSH is disabled (RunSSH: false)"
    else
      warn "Tailscale debug prefs could not be verified"
    fi
  fi
fi

# Display recent sudo audit log entries (WP-3C)
echo ""
echo "--- Recent sudo audit commands ---"
journalctl _COMM=sudo -n 10 --no-pager 2>/dev/null || \
  grep 'COMMAND=' /var/log/auth.log 2>/dev/null | tail -10 || \
  echo "(no sudo commands recorded yet)"

# 9. Summary
echo ""
echo "==========================================="
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Smoke test verification FAILED." >&2
  exit 1
fi
echo "All smoke tests PASSED. Devbox is fully operational."
exit 0
