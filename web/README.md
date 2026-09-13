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
- **Multi-Client & Per-Tab Session Isolation**:
  - Automatically isolates browser tabs and devices (`web-desktop-<id>`, `web-mobile-<id>`) into distinct linked tmux sessions sharing the underlying window group (`main`).
  - Each tab gets independent terminal dimensions, scrollback, and cursor positions without viewport collision or fighting.
  - Ephemeral linked sessions are automatically destroyed when the browser disconnects, preserving underlying background jobs.
- **Security & Authentication**:
  - **Token & Cookie Auth Bootstrap**: First-time login via `http://<devbox>:7681/?token=<secret>` sets an `HttpOnly`, `SameSite=Strict` cookie (`devbox_token`) and redirects to clean URL `/`. Token is also accepted via `Authorization: Bearer` or `X-Devbox-Token`.
  - **Origin Guard & CSRF / CSWSH Protection**: Validates `Origin` against `Host` and `X-Forwarded-Host` (supporting Tailscale serve / ingress proxies). Rejects cross-origin state-changing POST requests (403) and unauthorized WebSocket handshakes (1008).
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
http://<tailscale-ip>:7681/?token=<token>
```

---

## Testing

Run unit tests:
```bash
npm test
```
