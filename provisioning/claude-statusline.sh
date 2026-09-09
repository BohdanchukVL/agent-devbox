#!/usr/bin/env bash
# Claude Code statusLine hook for agent-devbox.
#
# Claude Code pipes a JSON snapshot of the session on stdin on every update
# (new assistant message, /compact, refreshInterval tick, ...). This script
#   1. persists the snapshot as ~/.devbox/claude-status/<session_id>.json so the
#      tmux status bar (tmux-status) can show context, cost and rate limits
#      for the pane that runs this session;
#   2. prints a one-line summary that Claude Code renders as its own status row.
# Schema: https://code.claude.com/docs/en/statusline.md
set -uo pipefail

STATE_DIR="${DEVBOX_CLAUDE_STATUS_DIR:-$HOME/.devbox/claude-status}"

input=$(cat)
[ -n "$input" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || sid=""
case "$sid" in
  "" | *[!A-Za-z0-9._-]*) sid="" ;; # session_id is a UUID; refuse anything path-like
esac

if [ -n "$sid" ] && mkdir -p "$STATE_DIR" 2>/dev/null; then
  chmod 0700 "$STATE_DIR" 2>/dev/null || true
  tmp="$STATE_DIR/.$sid.$$.tmp"
  if printf '%s\n' "$input" | jq -c . > "$tmp" 2>/dev/null; then
    chmod 0600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$STATE_DIR/$sid.json"
  else
    rm -f "$tmp"
  fi
  # forget sessions that have been silent for a day
  find "$STATE_DIR" -maxdepth 1 -name '*.json' -mmin +1440 -delete 2>/dev/null || true
fi

# Status row for Claude Code: model · ctx N% · 5h N% · 7d N% · $cost
# (cost only for API-key accounts: subscriptions report rate_limits instead)
printf '%s' "$input" | jq -r '
  def pct(x): if x == null then "?" else ((x | floor | tostring) + "%") end;
  def usd(x): ((x * 100) | round) as $c
              | "$" + (($c / 100) | floor | tostring) + "."
              + (("0" + (($c % 100) | tostring)) | .[-2:]);
  [ (.model.display_name // .model.id // "claude"),
    ("ctx " + pct(.context_window.used_percentage)),
    (if .rate_limits.five_hour.used_percentage != null then "5h " + pct(.rate_limits.five_hour.used_percentage) else empty end),
    (if .rate_limits.seven_day.used_percentage != null then "7d " + pct(.rate_limits.seven_day.used_percentage) else empty end),
    (if (.rate_limits == null) and ((.cost.total_cost_usd // 0) > 0) then usd(.cost.total_cost_usd) else empty end)
  ] | join(" · ")
' 2>/dev/null
exit 0
