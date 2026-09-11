#!/usr/bin/env bash
# devbox-metadata-guard — restrict cloud metadata endpoint (169.254.169.254)
# to root-only access. Blocks OUTPUT and DOCKER-USER chains, IPv4 and IPv6.
# Installed as a systemd service for persistence across reboots.
set -euo pipefail

METADATA_IP4="169.254.169.254"
METADATA_IP6="fd00:ec2::254"

if command -v iptables >/dev/null 2>&1; then
  # Host traffic: non-root users cannot query instance metadata
  iptables -C OUTPUT -m owner ! --uid-owner 0 -d "$METADATA_IP4" -j DROP 2>/dev/null || \
    iptables -A OUTPUT -m owner ! --uid-owner 0 -d "$METADATA_IP4" -j DROP 2>/dev/null || true

  # Container traffic: containers must never query instance metadata
  if iptables -L DOCKER-USER >/dev/null 2>&1; then
    iptables -C DOCKER-USER -d "$METADATA_IP4" -j DROP 2>/dev/null || \
      iptables -I DOCKER-USER -d "$METADATA_IP4" -j DROP 2>/dev/null || true
  fi
fi

if command -v ip6tables >/dev/null 2>&1; then
  # IPv6 IMDSv2 metadata endpoint (AWS / modern clouds)
  ip6tables -C OUTPUT -m owner ! --uid-owner 0 -d "$METADATA_IP6" -j DROP 2>/dev/null || \
    ip6tables -A OUTPUT -m owner ! --uid-owner 0 -d "$METADATA_IP6" -j DROP 2>/dev/null || true

  if ip6tables -L DOCKER-USER >/dev/null 2>&1; then
    ip6tables -C DOCKER-USER -d "$METADATA_IP6" -j DROP 2>/dev/null || \
      ip6tables -I DOCKER-USER -d "$METADATA_IP6" -j DROP 2>/dev/null || true
  fi
fi

echo "metadata guard active: $METADATA_IP4 & $METADATA_IP6 blocked for non-root and containers"
