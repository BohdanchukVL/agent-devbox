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
    case "$pane_cmd" in
        *agy*|*antigravity*) pane_agent="agy" ;;
        *claude*)            pane_agent="claude" ;;
        *codex*)             pane_agent="codex" ;;
        *)                   pane_agent="" ;;
    esac
    git_root=$(cd "$dir" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)
    [ -n "$git_root" ] && proj_dir="$git_root" || proj_dir="$dir"

    # 1. Claude Code
    claude_active=""
    claude_json="$HOME/.claude.json"
    [ -f "$claude_json" ] || claude_json="$HOME/.claude-cc/.claude.json"

    if [ -f "$claude_json" ]; then
        claude_data=$(jq -r --arg d "$proj_dir" --arg raw "$dir" '
          (.projects[$d] // .projects[$raw] // empty) |
          [
            ((.lastCost // 0) * 100 | floor / 100),
            (.lastSessionId // "-"),
            ((.lastStartTime // 0) / 1000 | floor),
            ((.lastTotalInputTokens // 0) + (.lastTotalCacheReadInputTokens // 0) + (.lastTotalCacheCreationInputTokens // 0))
          ] | @tsv
        ' "$claude_json" 2>/dev/null)

        if [ -n "$claude_data" ]; then
            IFS="$(printf '\t')" read -r cl_cost cl_sess_id cl_time cl_total_tokens <<EOF
$claude_data
EOF
            cl_busy=""
            [ "$pane_agent" = "claude" ] && cl_busy="⚡"
            for s in "$HOME/.claude/sessions/"*.json "$HOME/.claude-cc/sessions/"*.json; do
                [ -f "$s" ] || continue
                if grep -q "$proj_dir" "$s" 2>/dev/null && grep -q '"status":"busy"' "$s" 2>/dev/null; then
                    cl_busy="⚡"
                    break
                fi
            done

            cl_pct=""
            cl_tok_str=""
            slug=$(printf '%s' "$proj_dir" | tr '/' '-')
            session_file=""
            for base in "$HOME/.claude/projects" "$HOME/.claude-cc/projects"; do
                if [ "$cl_sess_id" != "-" ] && [ -f "$base/$slug/$cl_sess_id.jsonl" ]; then
                    session_file="$base/$slug/$cl_sess_id.jsonl"
                    break
                fi
            done

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

            cl_cost_str=""
            if [ -n "$cl_cost" ] && [ "$cl_cost" != "0" ] && [ "$cl_cost" != "-" ]; then
                cost_fmt=$(awk -v c="$cl_cost" 'BEGIN { printf "%.2f", c }' 2>/dev/null)
                [ -n "$cost_fmt" ] && cl_cost_str="\$${cost_fmt}"
            fi
            claude_active=1
        fi
    fi

    if [ "$pane_agent" = "claude" ] && [ -z "$claude_active" ]; then
        claude_active=1
        cl_busy="⚡"
        cl_pct=0
        cl_tok_str="0/200k"
        cl_time=$(date +%s)
    fi

    # 2. Codex CLI
    codex_active=""
    if [ -d "$HOME/.codex/sessions" ]; then
        latest_codex=$(ls -td "$HOME/.codex/sessions"/*/*/*/*.jsonl 2>/dev/null | head -n 1)
        if [ -n "$latest_codex" ] && [ -f "$latest_codex" ]; then
            if head -n 25 "$latest_codex" 2>/dev/null | grep -q "\"cwd\":\"$proj_dir\"" || head -n 25 "$latest_codex" 2>/dev/null | grep -q "\"cwd\":\"$dir\"" || [ "$pane_agent" = "codex" ]; then
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
                    cx_busy=""
                    if [ "$pane_agent" = "codex" ] || ! tail -n 5 "$latest_codex" 2>/dev/null | grep -q '"type":"task_complete"'; then
                        cx_busy="⚡"
                    fi
                    cx_pct=$(awk -v u="$cx_used" 'BEGIN { printf "%d", u + 0.5 }')
                    cx_tok_str="$(fmt_tokens "$cx_tok")/$(fmt_tokens "$cx_win")"
                    cx_time=$(stat -c %Y "$latest_codex" 2>/dev/null || stat -f %m "$latest_codex" 2>/dev/null || echo 0)
                    codex_active=1
                fi
            fi
        fi
    fi

    if [ "$pane_agent" = "codex" ] && [ -z "$codex_active" ]; then
        codex_active=1
        cx_busy="⚡"
        cx_pct=0
        cx_tok_str="0/200k"
        cx_time=$(date +%s)
    fi

    # 3. Antigravity CLI (agy)
    agy_active=""
    agy_busy=""
    agy_dir=""
    for d in "$HOME/.gemini/antigravity-cli" "$HOME/.antigravity" "$HOME/.config/antigravity-cli"; do
        if [ -d "$d" ]; then
            agy_dir="$d"
            break
        fi
    done

    if [ -n "$agy_dir" ]; then
        agy_conv_id=""
        agy_time=0

        # Check history.jsonl for conversation associated with this workspace
        if [ -f "$agy_dir/history.jsonl" ]; then
            agy_info=$(tail -n 100 "$agy_dir/history.jsonl" | jq -s -r --arg d "$proj_dir" --arg raw "$dir" '
              [.[] | select((.workspace == $d or .workspace == $raw or ($d != "" and ((.workspace // "") | endswith($d)))) and .conversationId != null)] | last // empty |
              "\(.conversationId) \((.timestamp // 0) / 1000 | floor)"
            ' 2>/dev/null)
            if [ -n "$agy_info" ]; then
                read -r agy_conv_id agy_time <<EOF
$agy_info
EOF
                if [ -n "$agy_conv_id" ] && [ -f "$agy_dir/presence/${agy_conv_id}.lock" ]; then
                    agy_busy="⚡"
                fi
                agy_active=1
            fi
        fi

        # If current pane is running agy, prioritize it
        if [ "$pane_agent" = "agy" ]; then
            agy_active=1
            agy_busy="⚡"
            [ -z "$agy_time" ] || [ "$agy_time" -eq 0 ] && agy_time=$(date +%s)
            if [ -z "$agy_conv_id" ]; then
                latest_lock=$(ls -t "$agy_dir/presence/"*.lock 2>/dev/null | head -n 1)
                [ -n "$latest_lock" ] && agy_conv_id=$(basename "$latest_lock" .lock)
                if [ -z "$agy_conv_id" ]; then
                    latest_brain=$(ls -td "$agy_dir/brain"/*/.system_generated/logs/transcript.jsonl 2>/dev/null | head -n 1)
                    [ -n "$latest_brain" ] && agy_conv_id=$(basename "$(dirname "$(dirname "$(dirname "$latest_brain")")")")
                fi
            fi
        fi

        agy_pct=""
        agy_tok_str=""
        if [ -n "$agy_conv_id" ]; then
            trans_file="$agy_dir/brain/$agy_conv_id/.system_generated/logs/transcript.jsonl"
            if [ -f "$trans_file" ]; then
                bytes=$(stat -c %s "$trans_file" 2>/dev/null || stat -f %z "$trans_file" 2>/dev/null || echo 0)
                if [ "$bytes" -gt 0 ] 2>/dev/null; then
                    approx_tok=$(( bytes / 4 ))
                    max_tok=1000000
                    agy_pct=$(( (approx_tok * 100) / max_tok ))
                    agy_tok_str="$(fmt_tokens "$approx_tok")/$(fmt_tokens "$max_tok")"
                fi
            fi
        fi

        # Default for active agy session without tokens yet
        if [ -n "$agy_active" ] && [ -z "$agy_pct" ]; then
            agy_pct=0
            agy_tok_str="0/1M"
        fi
    fi

    # 4. Agent selection: prioritize currently running pane command, then busy, then newest
    chosen=""
    if [ -n "$pane_agent" ]; then
        chosen="$pane_agent"
    elif [ -n "$cl_busy" ]; then
        chosen="claude"
    elif [ -n "$cx_busy" ]; then
        chosen="codex"
    elif [ -n "$agy_busy" ]; then
        chosen="agy"
    else
        max_t=-1
        if [ -n "$claude_active" ] && [ "${cl_time:-0}" -gt "$max_t" ]; then
            max_t="${cl_time:-0}"
            chosen="claude"
        fi
        if [ -n "$codex_active" ] && [ "${cx_time:-0}" -gt "$max_t" ]; then
            max_t="${cx_time:-0}"
            chosen="codex"
        fi
        if [ -n "$agy_active" ] && [ "${agy_time:-0}" -gt "$max_t" ]; then
            max_t="${agy_time:-0}"
            chosen="agy"
        fi
    fi

    case "$chosen" in
        claude)
            bar_str=$(render_bar "$cl_pct")
            out="#[fg=colour209,bold]claude${cl_busy}#[default]"
            [ -n "$bar_str" ] && out="$out $bar_str"
            [ -n "$cl_tok_str" ] && out="$out #[fg=colour246]$cl_tok_str#[default]"
            [ -n "$cl_cost_str" ] && out="$out #[fg=colour180]$cl_cost_str#[default]"
            printf ' %s' "$out"
            ;;
        codex)
            bar_str=$(render_bar "$cx_pct")
            out="#[fg=colour75,bold]codex${cx_busy}#[default]"
            [ -n "$bar_str" ] && out="$out $bar_str"
            [ -n "$cx_tok_str" ] && out="$out #[fg=colour246]$cx_tok_str#[default]"
            printf ' %s' "$out"
            ;;
        agy)
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
