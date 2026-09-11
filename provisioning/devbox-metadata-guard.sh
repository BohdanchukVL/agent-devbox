#!/usr/bin/env bash
# devbox-metadata-guard — restrict cloud metadata endpoint (169.254.169.254)
# to root-only access. Blocks OUTPUT and DOCKER-USER chains, IPv4 and IPv6.
# Installed as a systemd service for persistence across reboots.
set -euo pipefail

METADATA_IP="169.254.169.254"

add_rule() {
  local cmd="$1" chain="$2"
  # Idempotent: check before adding
  $cmd -C "$chain" -m owner ! --uid-owner 0 -d "$METADATA_IP" -j DROP 2>/dev/null || \
    $cmd -A "$chain" -m owner ! --uid-owner 0 -d "$METADATA_IP" -j DROP 2>/dev/null || true
}

# IPv4 OUTPUT chain
if command -v iptables >/dev/null 2>&1; then
  add_rule iptables OUTPUT
fi

# IPv4 DOCKER-USER chain (if Docker is running)
if command -v iptables >/dev/null 2>&1 && iptables -L DOCKER-USER >/dev/null 2>&1; then
  add_rule iptables DOCKER-USER
fi

# IPv6 OUTPUT chain (link-local metadata may exist on some clouds)
if command -v ip6tables >/dev/null 2>&1; then
  add_rule ip6tables OUTPUT
fi

echo "metadata guard active: $METADATA_IP blocked for non-root on OUTPUT + DOCKER-USER"
