# Concept validation

Verdict: **the concept is sound and implemented as designed.**

## Confirmed as-is

1. **Leader shortcut instead of intercepting system ⌘V** — terminals have no protocol for handing non-text clipboard to an app; global hooks need accessibility permissions and are fragile.
2. **OSC 52 intercepted client-side, before the terminal** — copy works regardless of terminal support.
3. **No server daemon** — SFTP is enough; the inbox is created from the client. The server needs only OpenSSH.
4. **Stack**: russh 0.62 + russh-sftp 2.3 + arboard 3.6 + crossterm.

## Review findings → v0.1 decisions

| # | Finding | Decision |
|---|---|---|
| 1 | `Ctrl+G` = BEL conflicts with readline abort | leader configurable; `Ctrl+G Ctrl+G` = literal BEL; 1.5 s timeout → literal |
| 2 | arboard cannot read file-list clipboard formats | v0.1 detects files from *text* paths (Finder Copy, drag-and-drop, `file://` URIs, escaped paths); native formats — v0.2 |
| 3 | bracketed-paste markers break old shells | output scanner tracks `CSI ?2004h/l`; markers only when the remote app enabled the mode |
| 4 | OSC 52 splits across read boundaries; query form; two terminators | streaming stateful parser with split-boundary tests; 1 MiB cap; query ignored |
| 5 | raw byte stdin beats event parsing for transparency | stdin read as raw bytes in a thread; crossterm only for raw mode + size; SIGWINCH via tokio |
| 6 | no known_hosts in the concept | TOFU like OpenSSH; hard refusal on key change |
| 7 | `/workspace` not universal | default inbox `~/.devbox/inbox`, configurable globally and per host |
| 8 | paths with spaces break the prompt | shell quoting on insert |
| 9 | inbox name collisions | `-1`, `-2`, … suffixes via SFTP checks |

## Deferred to v0.2

Native file-list clipboard formats; directories (tar); `Ctrl+G U/D` picker/download; Windows ssh-agent; agent certificates; passphrase keys; reverse push helper.

## v0.1.1 addendum

- Fixed three parser/decoder bugs (scanner desync after ST-terminated OSCs, stray ESC before an OSC, `percent_decode` panic on multi-byte UTF-8) — with regression tests.
- OSC 52 writes are policy-gated: `allow | notify | ask | deny`, global and per-host, default `notify`; `osc52_max_bytes` cap. Reads are never answered — write-only, like Windows Terminal / zellij / kitty. See README → "OSC 52 security".

## E2E verified (docker sshd + expect, real PTY)

- TOFU handshake, transparent shell, resize.
- Smart Paste text (bracketed under `?2004h`).
- Smart Paste file: SFTP upload → path typed → `cat` shows content.
- Smart Paste image: system clipboard → PNG in inbox (magic `89 50 4E 47` verified).
- OSC 52 remote → local system clipboard.
- `Ctrl+G Q` disconnect.
