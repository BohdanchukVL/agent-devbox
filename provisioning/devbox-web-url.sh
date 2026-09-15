#!/usr/bin/env bash
# Print the URL of the devbox-web gateway on this machine.
# Installed as ~/.devbox/bin/devbox-web-url; used by the MOTD, the deploy
# summary and `devbox web` in the CLI.
#
#   devbox-web-url                 http://agent-devbox.tailxyz.ts.net:7681/
#   devbox-web-url --short         http://agent-devbox:7681/  (MagicDNS short name)
#   devbox-web-url --with-token    appends ?token=… in token auth mode
#   devbox-web-url --qr            also draws the URL as a QR code (qrencode)
#   devbox-web-url --json          {"url":"…","auth":"tailscale|token","via":"serve|tailnet|local"}
set -euo pipefail

WITH_TOKEN=0
JSON=0
SHORT=0
QR=0
for arg in "$@"; do
  case "$arg" in
    --with-token) WITH_TOKEN=1 ;;
    --json) JSON=1 ;;
    --short) SHORT=1 ;;
    --qr) QR=1 ;;
    *) echo "usage: devbox-web-url [--short] [--with-token] [--qr] [--json]" >&2; exit 2 ;;
  esac
done

ENV_FILE="${DEVBOX_WEB_ENV:-$HOME/.devbox/web.env}"
AUTH=""
TOKEN=""
PORT=""
if [ -r "$ENV_FILE" ]; then
  AUTH=$(sed -n 's/^DEVBOX_WEB_AUTH=//p' "$ENV_FILE" | tail -n1)
  TOKEN=$(sed -n 's/^DEVBOX_WEB_TOKEN=//p' "$ENV_FILE" | tail -n1)
  PORT=$(sed -n 's/^PORT=//p' "$ENV_FILE" | tail -n1)
fi
if [ -z "$AUTH" ]; then
  if [ -n "$TOKEN" ]; then AUTH=token; else AUTH=tailscale; fi
fi
[ -n "$PORT" ] || PORT=7681

scheme=http
host=""
via=""
if command -v tailscale >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  STATUS=$(tailscale status --json 2>/dev/null || true)
  if [ -n "$STATUS" ] && [ "$(printf '%s' "$STATUS" | jq -r '.BackendState // empty')" = "Running" ]; then
    DNS=$(printf '%s' "$STATUS" | jq -r '.Self.DNSName // empty' | sed 's/\.$//')
    NAME=$(printf '%s' "$STATUS" | jq -r '.Self.HostName // empty')
    IP4=$(printf '%s' "$STATUS" | jq -r '.Self.TailscaleIPs[]? | select(test("^[0-9.]+$"))' | head -n1)
    if [ "$SHORT" = 1 ] && [ -n "$NAME" ]; then
      host="$NAME"
    else
      host="${DNS:-$IP4}"
    fi
    if [ -n "$DNS" ] && tailscale serve status 2>/dev/null | grep -q "https://$DNS"; then
      scheme=https
      PORT=443
      [ "$SHORT" = 1 ] || host="$DNS"
      via=serve
    else
      via=tailnet
    fi
  fi
fi
if [ -z "$host" ]; then
  host=127.0.0.1
  via=local
fi

if [ "$scheme" = https ] && [ "$PORT" = 443 ]; then
  url="$scheme://$host/"
else
  url="$scheme://$host:$PORT/"
fi
if [ "$AUTH" = token ] && [ "$WITH_TOKEN" = 1 ] && [ -n "$TOKEN" ]; then
  url="$url?token=$TOKEN"
fi

if [ "$JSON" = 1 ]; then
  printf '{"url":"%s","auth":"%s","via":"%s"}\n' "$url" "$AUTH" "$via"
else
  echo "$url"
  if [ "$via" = local ]; then
    echo "gateway is not on the tailnet; reach it with: ssh -L $PORT:127.0.0.1:$PORT <user>@<host>" >&2
  fi
  if [ "$QR" = 1 ]; then
    if command -v qrencode >/dev/null 2>&1; then
      echo
      qrencode -t UTF8 -m 2 "$url"
    else
      echo "qrencode is not installed (sudo apt-get install -y qrencode); use \`devbox web\` from your laptop instead" >&2
    fi
  fi
fi
