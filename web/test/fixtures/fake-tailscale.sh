#!/usr/bin/env bash
# Stand-in for the tailscale CLI used by the gateway tests (DEVBOX_TAILSCALE_BIN).
# Answers the two subcommands server.js relies on with canned JSON.
case "${1:-} ${2:-}" in
  "status --json")
    cat <<'JSON'
{"BackendState":"Running","Self":{"HostName":"agent-devbox-1","DNSName":"agent-devbox-1.tailxyz.ts.net.","TailscaleIPs":["100.64.0.10","fd7a:115c:a1e0::10"]}}
JSON
    ;;
  "whois --json")
    case "${3:-}" in
      100.64.0.20)
        cat <<'JSON'
{"Node":{"Name":"phone.tailxyz.ts.net.","Tags":null},"UserProfile":{"LoginName":"bohdan@example.com","DisplayName":"Bohdan"}}
JSON
        ;;
      100.64.0.30)
        cat <<'JSON'
{"Node":{"Name":"ci-runner.tailxyz.ts.net.","Tags":["tag:ci"]},"UserProfile":{"LoginName":"tagged-devices","DisplayName":"Tagged Devices"}}
JSON
        ;;
      *)
        echo "peer not found" >&2
        exit 1
        ;;
    esac
    ;;
  "ip -4")
    echo 100.64.0.10
    ;;
  *)
    echo "unsupported: $*" >&2
    exit 2
    ;;
esac
