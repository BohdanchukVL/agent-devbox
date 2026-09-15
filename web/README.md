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
- **Security & Authentication** (`DEVBOX_WEB_AUTH`):
  - **`tailscale` (default when the machine joined the tailnet)**: no token. The peer is identified by the tailnet: `tailscale whois` on the source address, or the `Tailscale-User-Login` header injected by `tailscale serve`. Tagged (machine) nodes are refused; `DEVBOX_WEB_USERS=a@x.com,b@x.com` narrows access to specific logins. Requests whose `Host` is not one of this node's names or addresses are refused with 421 (DNS-rebinding guard; extend with `DEVBOX_ALLOWED_HOSTS`).
  - **`token`**: shared secret. First-time login via `http://<devbox>:7681/?token=<secret>` sets an `HttpOnly`, `SameSite=Strict` cookie (`devbox_token`) and redirects to `/`. Also accepted via `Authorization: Bearer` or `X-Devbox-Token`.
  - **Origin Guard & CSRF / CSWSH Protection**: Validates `Origin` against `Host` and `X-Forwarded-Host` (supporting Tailscale serve / ingress proxies). Rejects cross-origin state-changing POST requests (403) and unauthorized WebSocket handshakes (401/403 at the handshake).
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

Listening on port `7681`. In `tailscale` mode the gateway binds the tailnet addresses plus loopback (`HOST=auto`); in `token` mode loopback only. Get the URL, or a QR code for your phone:

```bash
devbox web dev@<host>          # from your laptop (CLI)
~/.devbox/bin/devbox-web-url   # on the machine; --with-token appends the token in token mode
```

Without Tailscale, reach it over SSH: `ssh -L 7681:127.0.0.1:7681 dev@<host>` and open `http://127.0.0.1:7681/?token=<token>` (token in `~/.devbox/web.env`).

---

## Testing

Run unit tests:
```bash
npm test
```
