# devbox-web

Web gateway & companion layer for **agent-devbox**.

Provides browser and mobile terminal access over Tailscale / HTTPS with native mobile keyboard controls, multi-client viewport handling, and instant file/image drag-and-drop & clipboard paste into active agent sessions.

---

## Features

- **Xterm.js Terminal Bridge**: Full 256-color & TrueColor terminal streaming over WebSockets via `node-pty`.
- **Image & File Drag-and-Drop / Clipboard Paste**:
  - Drag & drop any file or screenshot directly into the browser window.
  - Paste images directly from the OS clipboard (`Cmd+V` / `Ctrl+V`).
  - Mobile touch buttons for instant 📷 Camera snap & 📎 File attachment.
  - Uploads are saved directly to `<active-pane-cwd>/.devbox-inbox/` (or `~/.devbox/inbox`) and the relative path is typed into your active prompt via `tmux send-keys`.
- **Multi-Device Grouped Sessions**:
  - Automatically isolates desktop and mobile clients (`main-web` vs `main-mobile`) while grouping them to the underlying windows and processes (`main`).
  - Active client determines the window geometry without breaking desktop terminal layouts when switching devices.
- **Mobile Touch Bar**: Quick-access touch controls for essential keys:
  - `Esc`, `Tab`, `Ctrl+C`, `Enter`, `/`
  - `▲` / `▼` history navigation
  - `🔍 Zoom` pane toggle (`tmux resize-pane -Z`)

---

## Service Management

`devbox-web` runs as a systemd user service (`devbox-web.service`):

```bash
# Check status
systemctl --user status devbox-web

# Restart
systemctl --user restart devbox-web

# View live logs
journalctl --user -u devbox-web -f
```

Listening by default on port `7681`. When connected to Tailscale, access directly via your Tailscale IP:
```
http://<tailscale-ip>:7681
```
