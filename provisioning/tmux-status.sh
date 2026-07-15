#!/bin/sh
# devbox tmux status segments. Called from ~/.tmux.conf status-right.
#   tmux-status cwd <dir>   → current dir, $HOME→~, long paths trimmed to …/parent/leaf
#   tmux-status git <dir>   → branch name (+ '*' if the tree is dirty), else empty
#   tmux-status load        → 1/5/15-minute load average
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
load)
    # only surface load when the box is actually busy — idle zeros are noise
    read -r one _ </proc/loadavg 2>/dev/null || exit 0
    awk -v l="$one" 'BEGIN { exit !(l + 0 >= 1.0) }' && printf 'load %s' "$one"
    ;;
esac
