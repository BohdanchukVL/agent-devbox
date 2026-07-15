#!/usr/bin/env bash
# Headless Chromium for agent web-testing (E2E, screenshots) via Playwright.
# Runs once as root via cloud-init after install-agents.sh when
# INSTALL_BROWSER=true. Playwright bundles a headless Chromium and pulls the
# exact OS libraries it needs — sidestepping Ubuntu's chromium-as-snap mess.
# The browser lands in the dev user's cache so project tests reuse it; a project
# that pins a different Playwright version just re-downloads its matching build
# (the heavy OS deps are already present, no sudo needed). Best-effort: a failed
# browser install never breaks the box.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

. /etc/devbox/devbox.env
U="$DEVBOX_USER"
H="/home/$U"
log() { echo "[devbox $(date -u +%H:%M:%S)] $*"; }

[ "${INSTALL_BROWSER:-false}" = "true" ] || { log "browser install skipped"; exit 0; }

log "installing Playwright + headless Chromium"
# playwright CLI into the dev-owned npm prefix (set up by install-agents.sh)
sudo -u "$U" -H npm install -g playwright || true

PW="$H/.npm-global/bin/playwright"
if [ -x "$PW" ]; then
  "$PW" install-deps chromium || true               # OS libraries (root/apt)
  sudo -u "$U" -H "$PW" install chromium || true    # browser → dev's cache
fi
log "browser install done"
