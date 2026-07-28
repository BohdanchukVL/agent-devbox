# devbox

**SSH terminal with a native clipboard and file bridge.**

Copy anything locally, paste it into your remote agent session:

```
local text     → remote text
local image    → remote file path
local file     → remote file path
remote yank    → local clipboard   (OSC 52)
```

Not a terminal emulator — a transparent proxy between the local TTY and the remote PTY (SSH), adding what plain `ssh` lacks. Built for remote agents (Claude Code, Codex) on a VPS: screenshot → `Ctrl+G V` → path lands in the agent's prompt.

## Usage

```bash
devbox connect prod                              # alias from ~/.ssh/config or devbox config
devbox connect dev@203.0.113.7 -p 2222 -i ~/.ssh/key
```

In-session (leader `Ctrl+G`, configurable):

| Keys | Action |
|---|---|
| `Ctrl+G` `V` | Smart Paste — text / image / files from the local clipboard |
| `Ctrl+G` `Q` | disconnect |
| `Ctrl+G` `?` | help |
| `Ctrl+G` `Ctrl+G` | literal `Ctrl+G` (BEL) |
| native `⌘V` / `Ctrl+Shift+V` | plain text paste, as always |

### Smart Paste

| Clipboard | Behavior |
|---|---|
| Text | pasted into the remote PTY (bracketed only if the remote app enabled it) |
| Image | PNG → SFTP → `<project>/.devbox-inbox/clipboard-<timestamp>.png` → path typed into the prompt |
| Local file path(s) | uploaded → quoted remote paths typed into the prompt |
| Directory | v0.3 |

`Ctrl+G V` is the explicit fallback; native ⌘V and drag-and-drop of files are
intercepted automatically (see below).

Reverse direction: OSC 52 yanks (tmux/Neovim) are intercepted client-side, before the terminal, and written to the local system clipboard — works even in terminals without OSC 52 support.

### Native paste of files (⌘V / drag-and-drop — no leader)

devbox scans the stdin bracketed-paste stream. When a native ⌘V or a
drag-and-drop turns out to be **existing local file paths**, it uploads them and
substitutes the remote paths — so a Finder ⌥⌘C (Copy as Pathname) then ⌘V, or a
drag-and-drop, just works without the leader. Anything that is not entirely
local paths (ordinary text) passes through byte-exact.

`paste_intercept`, global or per-host: `auto` (default, upload + status line) ·
`ask` (y/n first) · `off` (never intercept). False positive to know about: if
you genuinely mean to paste a path *as text*, use `ask`/`off` or `Ctrl+G V`.

### OSC 52 security

Anything that writes to the remote PTY can emit OSC 52 — including `cat` of a hostile file (clipboard poisoning: a payload ending in `\n` executes on paste). Therefore:

- Clipboard **read** (the `;?` query) is never answered — write-only by design (the industry consensus: Windows Terminal, zellij, kitty).
- Writes go through the `osc52` policy, global or per-host: `allow` — silent; `notify` (default) — size + control-char-sanitized preview + newline warning; `ask` — in-session y/n prompt; `deny` — block.
- Writes larger than `osc52_max_bytes` (default 100 KB, the xterm convention) are dropped.

## Config (`~/.config/devbox/config.toml`)

```toml
[defaults]
inbox_scope = "project"         # project (<cwd>/.devbox-inbox, via OSC 7) | global
inbox_retention_days = 7        # auto-delete uploads older than this (0 = keep)
inbox = "~/.devbox/inbox"       # global fallback when cwd is unknown
paste_template = "{path} "      # e.g. "Analyze the attached image: {path}\n"
leader = "ctrl+g"               # ctrl+t if you use Claude Code (frees Ctrl+G for its editor)
leader_timeout_ms = 1500
osc52 = "notify"                # allow | notify | ask | deny
osc52_max_bytes = 100000
paste_intercept = "auto"        # auto | ask | off (native ⌘V / drag-and-drop of files)
status = "auto"                 # auto | inline | notify | quiet (see below)

[hosts.prod]
host = "203.0.113.7"
port = 22
user = "deploy"
identity_file = "~/.ssh/prod_ed25519"
remote_command = "tmux new -A -s main"   # land straight in a persistent session

[hosts.shared-staging]
host = "staging.example.com"
osc52 = "deny"                  # untrusted box: no writes to my clipboard
```

Target resolution: devbox config → `~/.ssh/config` (HostName/User/Port/IdentityFile, `dev-*` globs) → `[user@]host`. Auth: ssh-agent (unix) → identity files → password. Host keys: known_hosts + TOFU, like OpenSSH.

## Server requirements

OpenSSH. No daemon, no HTTP, no database. The inbox directory is created over SFTP.

## Build

```bash
cargo build --release        # → target/release/devbox (single binary)
cargo test                   # units: OSC 52 parser, clipboard classification, ssh_config, policy
tests/e2e.exp                # live E2E against dockerized sshd — see tests/README.md
```

## Status output

devbox's own `[devbox] …` lines corrupt a full-screen TUI (Claude Code) that
owns the screen. `status` controls how they surface:

- `auto` (default) — desktop notification (OSC 9) while a remote TUI is active
  (it enabled bracketed paste), inline at a plain shell prompt. y/n prompts are
  always surfaced. Requires a terminal that renders OSC 9 (Ghostty, iTerm2).
- `inline` — always the inline line (old behavior).
- `notify` — always a desktop notification.
- `quiet` — no status; only y/n prompts show. The remote path typed into the
  prompt is your confirmation.

Uploaded-file paths are typed into the prompt regardless, so drag-and-drop of
an image into Claude Code just works without on-screen noise.

## Limitations

- Windows/Linux: no native clipboard file lists yet (CF_HDROP / `text/uri-list`)
  — text/images work, and text that is a path is still detected. macOS reads
  `public.file-url` natively. Windows ssh-agent (named pipe) — v0.3.
- No directories, no `Ctrl+G U/D` (picker/download) — v0.3.
- Passphrase-protected keys are skipped (use ssh-agent).
- Status lines and the `ask` prompt print over full-screen TUIs and vanish on redraw — prefer `notify`/`deny` for TUI-heavy sessions.
- Native paste containing the leader byte (BEL) swallows it — use `Ctrl+G V`, or change the leader.
