# devbox-osc7: report the shell's cwd via OSC 7 so the devbox client can scope
# uploaded files to the current project (<cwd>/.devbox-inbox/).
__devbox_osc7() {
  if [ -n "${TMUX:-}" ]; then
    printf '\033Ptmux;\033\033]7;file://%s%s\033\033\\\033\\' "${HOSTNAME:-h}" "$PWD"
  else
    printf '\033]7;file://%s%s\033\\' "${HOSTNAME:-h}" "$PWD"
  fi
}
case "${PROMPT_COMMAND:-}" in
*__devbox_osc7*) ;;
*) PROMPT_COMMAND="__devbox_osc7${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
esac
