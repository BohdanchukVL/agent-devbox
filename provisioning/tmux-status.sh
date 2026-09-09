#!/bin/bash
# devbox tmux status segments. Called from ~/.tmux.conf status-right.
#   tmux-status cwd <dir>   → current dir, $HOME→~, long paths trimmed to …/parent/leaf
#   tmux-status git <dir>   → branch name (+ '*' if the tree is dirty), else empty
#   tmux-status ai <dir>    → [bar = 5h session limit used] context tokens, cost of the agent in the pane
#   tmux-status load        → 1/5/15-minute load average
render_bar() {
    _pct="$1"
    _width="${2:-${AI_BAR_WIDTH:-10}}"
    [ -z "$_pct" ] && return
    [ "$_pct" -lt 0 ] 2>/dev/null && _pct=0
    [ "$_pct" -gt 100 ] 2>/dev/null && _pct=100

    if [ "$_pct" -ge 80 ]; then
        _col="#[fg=colour203,bold]"
    elif [ "$_pct" -ge 50 ]; then
        _col="#[fg=colour214]"
    else
        _col="#[fg=colour108]"
    fi

    _filled=$(( (_pct * _width + 50) / 100 ))
    [ "$_filled" -gt "$_width" ] && _filled="$_width"
    _empty=$(( _width - _filled ))

    _char_fill="${AI_BAR_FILL:-■}"
    _char_empty="${AI_BAR_EMPTY:-■}"

    _bar=""
    _i=0
    while [ "$_i" -lt "$_filled" ]; do _bar="${_bar}${_char_fill}"; _i=$((_i + 1)); done
    _bar_empty=""
    _i=0
    while [ "$_i" -lt "$_empty" ]; do _bar_empty="${_bar_empty}${_char_empty}"; _i=$((_i + 1)); done

    printf '#[fg=colour243][%s%s#[fg=colour238]%s#[fg=colour243]] %s%d%%#[default]' "$_col" "$_bar" "$_bar_empty" "$_col" "$_pct"
}

fmt_tokens() {
    _tok="$1"
    [ -z "$_tok" ] && return
    if [ "$_tok" -ge 1000000 ] 2>/dev/null; then
        awk -v t="$_tok" 'BEGIN { printf "%.1fM", t / 1000000 }' | sed 's/\.0M$/M/'
    elif [ "$_tok" -ge 1000 ] 2>/dev/null; then
        awk -v t="$_tok" 'BEGIN { printf "%dk", (t + 500) / 1000 }'
    else
        printf '%s' "$_tok"
    fi
}

render_cwd() {
    local d="${1:-$PWD}"
    case "$d" in
      "$HOME")   printf '~'; return ;;
      "$HOME"/*) d="~${d#"$HOME"}" ;;
    esac
    printf '%s' "$d" | awk -F/ 'NF<=3 { printf "%s", $0; next } { printf "…/%s/%s", $(NF-1), $NF }'
}

render_git() {
    local d="${1:-$HOME}"
    local b
    b=$(cd "$d" 2>/dev/null && git symbolic-ref --short HEAD 2>/dev/null) || return 0
    [ -n "$b" ] || return 0
    if (cd "$d" 2>/dev/null && { ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null || [ -n "$(git ls-files --others --exclude-standard 2>/dev/null | head -n 1)" ]; }); then
        b="$b*"
    fi
    printf '%s' "$b"
}

case "$1" in
cwd)
    render_cwd "${2:-$PWD}"
    ;;
git)
    render_git "${2:-$HOME}"
    ;;
ai)
    command -v jq >/dev/null 2>&1 || exit 0
    dir="${2:-$PWD}"
    [ -z "$dir" ] && dir="$PWD"
    pane_cmd="${3:-}"
    pane_pid="${4:-}"
    win_id="${5:-}"

    # Cache AI segment output per pane for 12s to avoid heavy repetitive checks across 5s status intervals
    cache_file="/tmp/.devbox-ai-cache-${pane_pid:-default}"
    now=$(date +%s 2>/dev/null || echo 0)
    if [ -f "$cache_file" ]; then
        cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)
        if [ $(( now - cache_mtime )) -lt 12 ]; then
            cat "$cache_file" 2>/dev/null
            exit 0
        fi
    fi
    print_ai() { printf ' %s' "$1" | tee "$cache_file" 2>/dev/null; }

    git_root=$(cd "$dir" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)
    [ -n "$git_root" ] && proj_dir="$git_root" || proj_dir="$dir"

    # Identify the command running in the active pane, checking child processes if wrapper (like node/python/bash/sh)
    full_cmd="$pane_cmd"
    if [ -n "$pane_pid" ]; then
        child_cmd=""
        if [ -d "/proc" ]; then
            child_pid=$(pgrep -P "$pane_pid" 2>/dev/null | head -n 1)
            [ -n "$child_pid" ] && child_cmd=$(tr '\0' ' ' < "/proc/$child_pid/cmdline" 2>/dev/null)
        fi
        if [ -z "$child_cmd" ]; then
            child_pids=$(pgrep -P "$pane_pid" 2>/dev/null | paste -sd, -)
            [ -n "$child_pids" ] && child_cmd=$(ps -o args= -p "$child_pids" 2>/dev/null)
        fi
        [ -n "$child_cmd" ] && full_cmd="$pane_cmd $child_cmd"
    fi

    running_agent=""
    agent_pane_pid="$pane_pid"
    case "$full_cmd" in
        *agy*|*antigravity*) running_agent="agy" ;;
        *codex*)             running_agent="codex" ;;
        *claude*)            running_agent="claude" ;;
    esac

    # If active pane is not an agent, check other panes in the current window
    if [ -z "$running_agent" ] && [ -n "$win_id" ]; then
        win_panes_info=$(tmux list-panes -t "$win_id" -F "#{pane_pid} #{pane_current_command}" 2>/dev/null)
        while read -r p_pid p_cmd; do
            [ -z "$p_pid" ] && continue
            cur_cmds="$p_cmd"
            c_pids=$(pgrep -P "$p_pid" 2>/dev/null | paste -sd, -)
            if [ -n "$c_pids" ]; then
                c_args=$(ps -o args= -p "$c_pids" 2>/dev/null)
                cur_cmds="$cur_cmds $c_args"
            fi
            case "$cur_cmds" in
                *agy*|*antigravity*) running_agent="agy"; agent_pane_pid="$p_pid"; break ;;
                *codex*)             running_agent="codex"; agent_pane_pid="$p_pid"; break ;;
                *claude*)            running_agent="claude"; agent_pane_pid="$p_pid"; break ;;
            esac
        done <<EOF
$win_panes_info
EOF
    fi

    # If no agent is running in this window, cache empty result and exit cleanly
    if [ -z "$running_agent" ]; then
        : > "$cache_file" 2>/dev/null
        exit 0
    fi

    case "$running_agent" in
    claude)
        # Everything comes from the statusLine hook (claude-statusline), which
        # persists Claude Code's own session JSON per session_id. No transcript
        # scraping, no undocumented ~/.claude.json fields, no busy heuristic:
        # Claude Code exposes no reliable "busy" signal on disk.
        status_dir="${DEVBOX_CLAUDE_STATUS_DIR:-$HOME/.devbox/claude-status}"
        cur_tok=""; win_size=""; cl_cost=""; has_rl=""
        rl5=""
        sf=""; newest=""
        if [ -d "$status_dir" ]; then
            # newest snapshot whose cwd / project dir matches this pane's dir or git
            # root; compare real paths too, in case /workspace or the project is a symlink
            dir_real=$(cd "$dir" 2>/dev/null && pwd -P) || dir_real="$dir"
            proj_real=$(cd "$proj_dir" 2>/dev/null && pwd -P) || proj_real="$proj_dir"
            while IFS= read -r f; do
                [ -n "$f" ] || continue
                [ -z "$newest" ] && newest="$f"
                if jq -e --arg d "$dir" --arg p "$proj_dir" --arg dr "$dir_real" --arg pr "$proj_real" '
                      [.cwd, .workspace.current_dir, .workspace.project_dir]
                      | map(select(type == "string")) | any(. == $d or . == $p or . == $dr or . == $pr)
                   ' "$f" >/dev/null 2>&1; then
                    sf="$f"
                    break
                fi
            done < <(ls -t "$status_dir"/*.json 2>/dev/null)
        fi

        if [ -n "$sf" ]; then
            cl_data=$(jq -r '
              def s(x): if x == null then "-" else (x | tostring) end;
              [ s(.context_window.used_percentage | if . == null then null else floor end),
                s(.context_window.current_usage
                  | if . == null then null
                    else ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)) end),
                s(.context_window.context_window_size),
                s(.cost.total_cost_usd),
                (if .rate_limits == null then "0" else "1" end)
              ] | join("\t")' "$sf" 2>/dev/null)
            IFS=$'\t' read -r _ cur_tok win_size cl_cost has_rl <<<"$cl_data"
            [ "$cur_tok" = "-" ] && cur_tok=""
            [ "$win_size" = "-" ] && win_size=""
            [ "$cl_cost" = "-" ] && cl_cost=""
        fi

        # the 5h session limit is account-wide: fall back to the newest snapshot for it
        rl_src="$sf"
        [ -z "$rl_src" ] && rl_src="$newest"
        if [ -n "$rl_src" ]; then
            rl5=$(jq -r --argjson now "$(date +%s)" '
              .rate_limits.five_hour
              | if (. | type) != "object" or .used_percentage == null
                   or (.resets_at != null and .resets_at < $now) then empty
                else (.used_percentage | floor | if . < 0 then 0 elif . > 100 then 100 else . end) end' "$rl_src" 2>/dev/null)
        fi

        # Layout: claude [bar = 5h session limit USED, fills up as you spend] N%  ctx-tokens/window  $cost
        # The bar is the session limit, never the context window: context is the token label.
        out="#[fg=colour209,bold]claude#[default]"
        if [ -z "$sf" ] && [ -z "$newest" ]; then
            out="$out #[fg=colour243]no statusLine#[default]"
        else
            if [ -n "$rl5" ]; then
                bar_str=$(render_bar "$rl5")
                [ -n "$bar_str" ] && out="$out $bar_str"
            fi
            if [ -n "$cur_tok" ] && [ -n "$win_size" ]; then
                out="$out #[fg=colour246]$(fmt_tokens "$cur_tok")/$(fmt_tokens "$win_size")#[default]"
            fi
            # dollar cost only for API-key accounts; subscriptions report rate_limits instead
            if [ "$has_rl" != "1" ] && [ -n "$cl_cost" ]; then
                cost_fmt=$(awk -v c="$cl_cost" 'BEGIN { if (c + 0 > 0) printf "%.2f", c }' 2>/dev/null)
                [ -n "$cost_fmt" ] && out="$out #[fg=colour180]\$${cost_fmt}#[default]"
            fi
        fi
        print_ai "$out"
        ;;

    codex)
        cx_busy=""
        cx_tok_str=""
        cx_lim=""
        if [ -d "$HOME/.codex/sessions" ]; then
            active_codex=""
            # 1. Try finding open session file from agent pane process tree via /proc
            if [ -n "$agent_pane_pid" ]; then
                pids="$agent_pane_pid"
                for child in $(pgrep -P "$agent_pane_pid" 2>/dev/null); do
                    pids="$pids $child"
                    for gchild in $(pgrep -P "$child" 2>/dev/null); do
                        pids="$pids $gchild"
                    done
                done
                for p in $pids; do
                    if [ -d "/proc/$p/fd" ]; then
                        s=$(readlink /proc/"$p"/fd/* 2>/dev/null | grep "/\.codex/sessions/.*\.jsonl$" | head -n 1)
                        if [ -n "$s" ] && [ -f "$s" ]; then
                            active_codex="$s"
                            break
                        fi
                        lock=$(readlink /proc/"$p"/fd/* 2>/dev/null | grep "/thread-writer-locks/.*\.lock$" | head -n 1)
                        if [ -n "$lock" ]; then
                            th_id=$(basename "$lock" .lock)
                            s=$(find "$HOME/.codex/sessions" -name "*${th_id}*.jsonl" 2>/dev/null | head -n 1)
                            if [ -n "$s" ] && [ -f "$s" ]; then
                                active_codex="$s"
                                break
                            fi
                        fi
                    fi
                done
            fi

            # 2. Fallback: match recent sessions for current project
            if [ -z "$active_codex" ]; then
                for f in $(ls -td "$HOME/.codex/sessions"/*/*/*/*.jsonl 2>/dev/null | head -n 5); do
                    if head -n 25 "$f" 2>/dev/null | grep -q "\"cwd\":\"$proj_dir\"" || head -n 25 "$f" 2>/dev/null | grep -q "\"cwd\":\"$dir\""; then
                        active_codex="$f"
                        break
                    fi
                done
            fi

            now=$(date +%s)
            cx_used=""
            cx_tok=""
            cx_win=""

            # Extract rate limits & tokens from active session if present
            if [ -n "$active_codex" ] && [ -f "$active_codex" ]; then
                turn_state=$(tail -n 35 "$active_codex" 2>/dev/null | jq -s -r '
                  [.[] | select(.payload.type=="task_started" or .payload.type=="task_complete")] | last | .payload.type // empty
                ' 2>/dev/null)
                [ "$turn_state" = "task_started" ] && cx_busy="⚡"

                cx_data=$(tail -n 35 "$active_codex" 2>/dev/null | jq -s -r --argjson now "$now" '
                  [.[] | select(.payload.type=="token_count" and .payload.rate_limits != null)] | last // null |
                  if . == null then empty else
                    (.payload.rate_limits.primary // {}) as $p |
                    (.payload.rate_limits.secondary // {}) as $s |
                    (if ($p.resets_at != null and $p.resets_at < $now) then 0 else ($p.used_percent // 0) end) as $p_used |
                    (if ($s.resets_at != null and $s.resets_at < $now) then 0 else ($s.used_percent // 0) end) as $s_used |
                    ([$p_used, $s_used] | max) as $max_used |
                    (.payload.info.last_token_usage.total_tokens // 0) as $tok |
                    (.payload.info.model_context_window // 258400) as $win |
                    "\($max_used) \($tok) \($win)"
                  end
                ' 2>/dev/null)
                if [ -n "$cx_data" ]; then
                    read -r cx_used cx_tok cx_win <<EOF
$cx_data
EOF
                fi
            fi

            # Fallback for rate limits on launch before first prompt in a new session:
            # Rate limits are account-wide, so get freshest limits from most recent session across the system.
            if [ -z "$cx_used" ]; then
                for f in $(ls -td "$HOME/.codex/sessions"/*/*/*/*.jsonl 2>/dev/null | head -n 5); do
                    global_rl=$(tail -n 35 "$f" 2>/dev/null | jq -s -r --argjson now "$now" '
                      [.[] | select(.payload.type=="token_count" and .payload.rate_limits != null)] | last // null |
                      if . == null then empty else
                        (.payload.rate_limits.primary // {}) as $p |
                        (.payload.rate_limits.secondary // {}) as $s |
                        (if ($p.resets_at != null and $p.resets_at < $now) then 0 else ($p.used_percent // 0) end) as $p_used |
                        (if ($s.resets_at != null and $s.resets_at < $now) then 0 else ($s.used_percent // 0) end) as $s_used |
                        ([$p_used, $s_used] | max) as $max_used |
                        "\($max_used)"
                      end
                    ' 2>/dev/null)
                    if [ -n "$global_rl" ]; then
                        cx_used="$global_rl"
                        cx_tok=0
                        cx_win=258400
                        break
                    fi
                done
            fi

            # bar = bottleneck rate limit USED (max of primary/secondary)
            if [ -n "$cx_used" ]; then
                cx_lim=$(awk -v u="$cx_used" 'BEGIN { if (u < 0) u = 0; if (u > 100) u = 100; printf "%d", u }')
            fi
            [ "$cx_tok" -ge 0 ] 2>/dev/null || cx_tok=0
            [ "$cx_win" -gt 0 ] 2>/dev/null || cx_win=258400
            cx_tok_str="$(fmt_tokens "$cx_tok")/$(fmt_tokens "$cx_win")"
        fi

        out="#[fg=colour75,bold]codex${cx_busy}#[default]"
        if [ -n "$cx_lim" ]; then
            bar_str=$(render_bar "$cx_lim")
            [ -n "$bar_str" ] && out="$out $bar_str"
        fi
        [ -n "$cx_tok_str" ] && out="$out #[fg=colour246]$cx_tok_str#[default]"
        print_ai "$out"
        ;;

    agy)
        agy_dir=""
        for d in "$HOME/.gemini/antigravity-cli" "$HOME/.antigravity" "$HOME/.config/antigravity-cli"; do
            if [ -d "$d" ]; then
                agy_dir="$d"
                break
            fi
        done

        agy_busy=""
        agy_pct=""
        agy_tok_str=""
        agy_conv_id=""

        if [ -n "$agy_dir" ]; then
            if [ -f "$agy_dir/history.jsonl" ]; then
                agy_info=$(tail -n 100 "$agy_dir/history.jsonl" | jq -s -r --arg d "$proj_dir" --arg raw "$dir" '
                  [.[] | select((.workspace == $d or .workspace == $raw or ($d != "" and ((.workspace // "") | endswith($d)))) and .conversationId != null)] | last // empty |
                  "\(.conversationId)"
                ' 2>/dev/null)
                [ -n "$agy_info" ] && agy_conv_id="$agy_info"
            fi

            if [ -z "$agy_conv_id" ]; then
                latest_lock=$(ls -t "$agy_dir/presence/"*.lock 2>/dev/null | head -n 1)
                [ -n "$latest_lock" ] && agy_conv_id=$(basename "$latest_lock" .lock)
                if [ -z "$agy_conv_id" ]; then
                    latest_brain=$(ls -td "$agy_dir/brain"/*/.system_generated/logs/transcript.jsonl 2>/dev/null | head -n 1)
                    [ -n "$latest_brain" ] && agy_conv_id=$(basename "$(dirname "$(dirname "$(dirname "$latest_brain")")")")
                fi
            fi

            if [ -n "$agy_conv_id" ]; then
                trans_file="$agy_dir/brain/$agy_conv_id/.system_generated/logs/transcript.jsonl"
                if [ -f "$trans_file" ]; then
                    bytes=$(stat -c %s "$trans_file" 2>/dev/null || stat -f %z "$trans_file" 2>/dev/null || echo 0)
                    if [ "$bytes" -gt 0 ] 2>/dev/null; then
                        approx_tok=$(( bytes / 4 ))
                        max_tok=1000000
                        agy_pct=$(( (approx_tok * 100) / max_tok ))
                        agy_tok_str="$(fmt_tokens "$approx_tok")/$(fmt_tokens "$max_tok")"

                        agy_state=$(tail -n 1 "$trans_file" 2>/dev/null | jq -r '
                          if .type == "USER_INPUT" then "busy"
                          elif .type == "PLANNER_RESPONSE" and (.tool_calls != null and (.tool_calls | length > 0)) then "busy"
                          elif .type != "PLANNER_RESPONSE" then "busy"
                          else "idle" end
                        ' 2>/dev/null)
                        [ "$agy_state" = "busy" ] && agy_busy="⚡"
                    fi
                fi
            fi
        fi

        [ -z "$agy_pct" ] && agy_pct=0 && agy_tok_str="0/1M"

        bar_str=$(render_bar "$agy_pct")
        out="#[fg=colour141,bold]agy${agy_busy}#[default]"
        [ -n "$bar_str" ] && out="$out $bar_str"
        [ -n "$agy_tok_str" ] && out="$out #[fg=colour246]$agy_tok_str#[default]"
        print_ai "$out"
        ;;
    esac
    ;;
load)
    # only surface load when the box is actually busy — idle zeros are noise
    read -r one _ </proc/loadavg 2>/dev/null || exit 0
    awk -v l="$one" 'BEGIN { exit !(l + 0 >= 1.0) }' && printf 'load %s' "$one"
    ;;
all)
    dir="${2:-$PWD}"
    pane_cmd="${3:-}"
    pane_pid="${4:-}"
    win_id="${5:-}"

    # 1. cwd segment
    cwd_fmt=$(render_cwd "$dir")

    # 2. git segment
    git_str=$(render_git "$dir")
    git_fmt=""
    [ -n "$git_str" ] && git_fmt=" #[fg=colour108]$git_str"

    # 3. ai segment
    ai_fmt=$(bash "$0" ai "$dir" "$pane_cmd" "$pane_pid" "$win_id")

    # 4. load segment
    load_fmt=""
    read -r one _ </proc/loadavg 2>/dev/null || one=""
    if [ -n "$one" ]; then
        load_val=$(awk -v l="$one" 'BEGIN { if (l + 0 >= 1.0) printf " #[fg=colour214]load %s", l }')
        load_fmt="$load_val"
    fi

    printf "#[fg=colour180,bold]%s%s%s%s " "$cwd_fmt" "$git_fmt" "$ai_fmt" "$load_fmt"
    ;;
esac
