#!/bin/sh
# devbox tmux status segments. Called from ~/.tmux.conf status-right.
#   tmux-status cwd <dir>   → current dir, $HOME→~, long paths trimmed to …/parent/leaf
#   tmux-status git <dir>   → branch name (+ '*' if the tree is dirty), else empty
#   tmux-status ai <dir>    → AI session context limit progress bar, token usage & cost
#   tmux-status load        → 1/5/15-minute load average
render_bar() {
    _pct="$1"
    _width="${2:-${AI_BAR_WIDTH:-8}}"
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

    _bar=""
    _i=0
    while [ "$_i" -lt "$_filled" ]; do _bar="${_bar}█"; _i=$((_i + 1)); done
    _i=0
    while [ "$_i" -lt "$_empty" ]; do _bar="${_bar}░"; _i=$((_i + 1)); done

    printf '#[fg=colour243][%s%s#[fg=colour243]] %s%d%%#[default]' "$_col" "$_bar" "$_col" "$_pct"
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

case "$1" in
cwd)
    dir="${2:-$PWD}"
    case "$dir" in
      "$HOME")   printf '~'; exit 0 ;;
      "$HOME"/*) dir="~${dir#"$HOME"}" ;;
    esac
    # keep it short: deep paths collapse to …/<parent>/<leaf>
    printf '%s' "$dir" | awk -F/ 'NF<=3 { printf "%s", $0; next } { printf "…/%s/%s", $(NF-1), $NF }'
    ;;
git)
    dir="${2:-$HOME}"
    b=$(cd "$dir" 2>/dev/null && git symbolic-ref --short HEAD 2>/dev/null) || exit 0
    [ -n "$b" ] || exit 0
    [ -n "$(cd "$dir" && git status --porcelain 2>/dev/null)" ] && b="$b*"
    printf '%s' "$b"
    ;;
ai)
    command -v jq >/dev/null 2>&1 || exit 0
    dir="${2:-$PWD}"
    [ -z "$dir" ] && dir="$PWD"
    pane_cmd="${3:-}"
    pane_pid="${4:-}"
    win_id="${5:-}"

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
            child_pids=$(pgrep -P "$pane_pid" 2>/dev/null)
            [ -n "$child_pids" ] && child_cmd=$(ps -o args= -p $child_pids 2>/dev/null)
        fi
        [ -n "$child_cmd" ] && full_cmd="$pane_cmd $child_cmd"
    fi

    running_agent=""
    case "$full_cmd" in
        *agy*|*antigravity*) running_agent="agy" ;;
        *codex*)             running_agent="codex" ;;
        *claude*)            running_agent="claude" ;;
    esac

    # If active pane is not an agent, check other panes in the current window
    if [ -z "$running_agent" ] && [ -n "$win_id" ]; then
        win_panes_info=$(tmux list-panes -t "$win_id" -F "#{pane_pid} #{pane_current_command}" 2>/dev/null)
        all_win_cmds=""
        while read -r p_pid p_cmd; do
            [ -z "$p_pid" ] && continue
            all_win_cmds="$all_win_cmds $p_cmd"
            c_pids=$(pgrep -P "$p_pid" 2>/dev/null)
            if [ -n "$c_pids" ]; then
                c_args=$(ps -o args= -p $c_pids 2>/dev/null)
                all_win_cmds="$all_win_cmds $c_args"
            fi
        done <<EOF
$win_panes_info
EOF

        case "$all_win_cmds" in
            *agy*|*antigravity*) running_agent="agy" ;;
            *codex*)             running_agent="codex" ;;
            *claude*)            running_agent="claude" ;;
        esac
    fi

    # If no agent is running in this window, exit cleanly — do not show stale history
    [ -z "$running_agent" ] && exit 0

    case "$running_agent" in
    claude)
        claude_json="$HOME/.claude.json"
        [ -f "$claude_json" ] || claude_json="$HOME/.claude-cc/.claude.json"
        cl_cost=""
        cl_pct=""
        cl_tok_str=""
        cl_cost_str=""
        cl_busy=""

        active_sess_id=""
        for s in "$HOME/.claude/sessions/"*.json "$HOME/.claude-cc/sessions/"*.json; do
            [ -f "$s" ] || continue
            if grep -q "$proj_dir" "$s" 2>/dev/null; then
                active_sess_id=$(jq -r '.sessionId // empty' "$s" 2>/dev/null)
                if grep -q '"status":"busy"' "$s" 2>/dev/null; then
                    cl_busy="⚡"
                fi
                break
            fi
        done

        if [ -f "$claude_json" ]; then
            claude_data=$(jq -r --arg d "$proj_dir" --arg raw "$dir" '
              (.projects[$d] // .projects[$raw] // empty) |
              [
                ((.lastCost // 0) * 100 | floor / 100),
                (.lastSessionId // "-"),
                ((.lastTotalInputTokens // 0) + (.lastTotalCacheReadInputTokens // 0) + (.lastTotalCacheCreationInputTokens // 0))
              ] | @tsv
            ' "$claude_json" 2>/dev/null)

            if [ -n "$claude_data" ]; then
                IFS="$(printf '\t')" read -r cl_cost cl_sess_id cl_total_tokens <<EOF
$claude_data
EOF
                slug=$(printf '%s' "$proj_dir" | tr '/' '-')
                session_file=""
                for base in "$HOME/.claude/projects" "$HOME/.claude-cc/projects"; do
                    if [ -n "$active_sess_id" ] && [ -f "$base/$slug/$active_sess_id.jsonl" ]; then
                        session_file="$base/$slug/$active_sess_id.jsonl"
                        break
                    elif [ "$cl_sess_id" != "-" ] && [ -f "$base/$slug/$cl_sess_id.jsonl" ]; then
                        session_file="$base/$slug/$cl_sess_id.jsonl"
                        break
                    fi
                done
                if [ -z "$session_file" ]; then
                    for base in "$HOME/.claude/projects" "$HOME/.claude-cc/projects"; do
                        latest=$(ls -td "$base/$slug"/*.jsonl 2>/dev/null | head -n 1)
                        [ -n "$latest" ] && session_file="$latest" && break
                    done
                fi

                if [ -n "$session_file" ]; then
                    tok_data=$(tail -n 25 "$session_file" 2>/dev/null | jq -s -r '
                      [.[] | select(.message.usage != null)] | last // empty |
                      ((.message.usage.input_tokens // 0) + (.message.usage.cache_read_input_tokens // 0) + (.message.usage.cache_creation_input_tokens // 0)) as $tok |
                      "\($tok) \(.message.model // "-")"
                    ' 2>/dev/null)
                    if [ -n "$tok_data" ]; then
                        read -r cur_tok model <<EOF
$tok_data
EOF
                        if [ "$cur_tok" -gt 0 ] 2>/dev/null; then
                            max_tok=200000
                            case "$model" in
                                *1m*|*1M*) max_tok=1000000 ;;
                                *) [ "$cur_tok" -gt 200000 ] 2>/dev/null && max_tok=1000000 ;;
                            esac
                            cl_pct=$(( (cur_tok * 100) / max_tok ))
                            cl_tok_str="$(fmt_tokens "$cur_tok")/$(fmt_tokens "$max_tok")"
                        fi
                    fi
                fi

                if [ -n "$cl_cost" ] && [ "$cl_cost" != "0" ] && [ "$cl_cost" != "-" ]; then
                    cost_fmt=$(awk -v c="$cl_cost" 'BEGIN { printf "%.2f", c }' 2>/dev/null)
                    [ -n "$cost_fmt" ] && cl_cost_str="\$${cost_fmt}"
                fi
            fi
        fi

        [ -z "$cl_pct" ] && cl_pct=0 && cl_tok_str="0/200k"

        bar_str=$(render_bar "$cl_pct")
        out="#[fg=colour209,bold]claude${cl_busy}#[default]"
        [ -n "$bar_str" ] && out="$out $bar_str"
        [ -n "$cl_tok_str" ] && out="$out #[fg=colour246]$cl_tok_str#[default]"
        [ -n "$cl_cost_str" ] && out="$out #[fg=colour180]$cl_cost_str#[default]"
        printf ' %s' "$out"
        ;;

    codex)
        cx_busy=""
        cx_pct=""
        cx_tok_str=""
        if [ -d "$HOME/.codex/sessions" ]; then
            latest_codex=""
            for f in $(ls -td "$HOME/.codex/sessions"/*/*/*/*.jsonl 2>/dev/null | head -n 15); do
                if head -n 25 "$f" 2>/dev/null | grep -q "\"cwd\":\"$proj_dir\"" || head -n 25 "$f" 2>/dev/null | grep -q "\"cwd\":\"$dir\""; then
                    latest_codex="$f"
                    break
                fi
            done
            [ -z "$latest_codex" ] && latest_codex=$(ls -td "$HOME/.codex/sessions"/*/*/*/*.jsonl 2>/dev/null | head -n 1)

            if [ -n "$latest_codex" ] && [ -f "$latest_codex" ]; then
                cx_data=$(tail -n 25 "$latest_codex" | jq -s -r '
                  [.[] | select(.payload.type=="token_count" and .payload.rate_limits != null)] | last // empty |
                  .payload.rate_limits.primary.used_percent as $used |
                  .payload.info.last_token_usage.total_tokens as $last_tok |
                  .payload.info.model_context_window as $ctx_win |
                  "\($used) \($last_tok) \($ctx_win)"
                ' 2>/dev/null)
                if [ -n "$cx_data" ]; then
                    read -r cx_used cx_tok cx_win <<EOF
$cx_data
EOF
                    if ! tail -n 5 "$latest_codex" 2>/dev/null | grep -q 'task_complete'; then
                        cx_busy="⚡"
                    fi
                    cx_pct=$(awk -v u="$cx_used" 'BEGIN { printf "%d", u + 0.5 }')
                    cx_tok_str="$(fmt_tokens "$cx_tok")/$(fmt_tokens "$cx_win")"
                fi
            fi
        fi

        [ -z "$cx_pct" ] && cx_pct=0 && cx_tok_str="0/200k"

        bar_str=$(render_bar "$cx_pct")
        out="#[fg=colour75,bold]codex${cx_busy}#[default]"
        [ -n "$bar_str" ] && out="$out $bar_str"
        [ -n "$cx_tok_str" ] && out="$out #[fg=colour246]$cx_tok_str#[default]"
        printf ' %s' "$out"
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
        printf ' %s' "$out"
        ;;
    esac
    ;;
load)
    # only surface load when the box is actually busy — idle zeros are noise
    read -r one _ </proc/loadavg 2>/dev/null || exit 0
    awk -v l="$one" 'BEGIN { exit !(l + 0 >= 1.0) }' && printf 'load %s' "$one"
    ;;
esac
