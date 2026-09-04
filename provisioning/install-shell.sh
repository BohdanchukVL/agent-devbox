#!/usr/bin/env bash
# Interactive-shell UX layer: zsh + autosuggestions/highlighting, starship,
# fzf keybindings, eza/bat/zoxide, lazygit + delta. Runs once as root via
# cloud-init; every step is tolerant so a single missing tool never fails the
# box, and ~/.zshrc guards each tool with `command -v`.
set -uo pipefail
trap 'touch /etc/devbox/.failed 2>/dev/null || true' ERR
export DEBIAN_FRONTEND=noninteractive

. /etc/devbox/devbox.env
U="$DEVBOX_USER"
H="/home/$U"
log() { echo "[devbox $(date -u +%H:%M:%S)] $*"; }

log "installing zsh + CLI tools from apt"
apt-get update -y
# zsh is essential; the rest are best-effort (guarded in .zshrc)
apt-get install -y zsh
apt-get install -y zsh-autosuggestions zsh-syntax-highlighting bat eza zoxide git-delta || true

log "installing editor + dev CLI tools"
# neovim/vim editors, fd (fast find), shellcheck, direnv, tree, httpie (API testing)
apt-get install -y neovim vim fd-find tree shellcheck direnv httpie || true

arch=$(dpkg --print-architecture) # amd64 | arm64

if ! command -v yq >/dev/null 2>&1; then
  log "installing yq"
  case "$arch" in amd64) ya=amd64 ;; arm64) ya=arm64 ;; *) ya= ;; esac
  # mikefarah/yq — single static binary; apt ships a different, jq-wrapper yq
  [ -n "$ya" ] && curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${ya}" \
    -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq || true
fi

if ! command -v starship >/dev/null 2>&1; then
  log "installing starship"
  curl -fsSL https://starship.rs/install.sh | sh -s -- -y -b /usr/local/bin || true
fi

if ! command -v zoxide >/dev/null 2>&1; then
  log "installing zoxide (fallback)"
  curl -fsSL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh -s -- --bin-dir /usr/local/bin || true
fi

if ! command -v lazygit >/dev/null 2>&1; then
  log "installing lazygit"
  case "$arch" in amd64) la=x86_64 ;; arm64) la=arm64 ;; *) la= ;; esac
  ver=$(curl -sIL https://github.com/jesseduffield/lazygit/releases/latest | grep -i '^location:' | tail -n 1 | sed -E 's/.*\/v?([0-9.]+).*/\1/' | tr -d '\r\n')
  if [ -z "$ver" ]; then
    ver=$(curl -fsSL https://api.github.com/repos/jesseduffield/lazygit/releases/latest 2>/dev/null | jq -r .tag_name 2>/dev/null | sed 's/^v//')
  fi
  if [ -n "$la" ] && [ -n "$ver" ] && [ "$ver" != "null" ]; then
    curl -fsSL "https://github.com/jesseduffield/lazygit/releases/download/v${ver}/lazygit_${ver}_Linux_${la}.tar.gz" \
      | tar xz -C /usr/local/bin lazygit || true
  fi
fi

log "configuring zsh for $U"
install -m 0644 -o "$U" -g "$U" /opt/devbox/zshrc "$H/.zshrc"
chsh -s "$(command -v zsh)" "$U" || true

log "configuring git UX for $U"
if command -v delta >/dev/null 2>&1; then
  sudo -u "$U" -H git config --global core.pager delta
  sudo -u "$U" -H git config --global interactive.diffFilter 'delta --color-only'
  sudo -u "$U" -H git config --global delta.navigate true
  sudo -u "$U" -H git config --global merge.conflictStyle zdiff3
fi
sudo -u "$U" -H git config --global alias.st status
sudo -u "$U" -H git config --global alias.co checkout
sudo -u "$U" -H git config --global alias.br branch
sudo -u "$U" -H git config --global alias.lg "log --oneline --graph --decorate -20"

log "shell setup done"
