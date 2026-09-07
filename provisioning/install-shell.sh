#!/usr/bin/env bash
# Interactive-shell UX layer: zsh + autosuggestions/highlighting, starship,
# fzf keybindings, eza/bat/zoxide, lazygit + delta. Runs once as root via
# cloud-init; every step is tolerant so a single missing tool never fails the
# box, and ~/.zshrc guards each tool with `command -v`.
set -euo pipefail
trap 'touch /etc/devbox/.failed 2>/dev/null || true' ERR
export DEBIAN_FRONTEND=noninteractive

# shellcheck source=/dev/null
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
  YQ_VERSION="${YQ_VERSION:-v4.44.3}"
  if [ -n "$ya" ]; then
    if curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ya}" -o /usr/local/bin/yq; then
      chmod +x /usr/local/bin/yq
    else
      log "yq install failed (skipping)"
    fi
  fi
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
  LAZYGIT_VERSION="${LAZYGIT_VERSION:-0.44.1}"
  if [ -n "$la" ]; then
    curl -fsSL "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_${la}.tar.gz" \
      | tar xz -C /usr/local/bin lazygit || log "lazygit install failed (skipping)"
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
