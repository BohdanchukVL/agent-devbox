/**
 * Transport Manager: WebSocket with devbox-terminal.v2 subprotocol,
 * typed envelopes, reconnect with exponential backoff, and lifecycle awareness.
 */

import {
  PROTOCOL_VERSION,
  MSG_HELLO,
  MSG_INPUT,
  MSG_RESIZE,
  MSG_ACTION,
  MSG_CONTROL,
  MSG_PANES,
  MSG_PING,
  MSG_PONG,
  MSG_ERROR,
  MSG_ACK,
  createHello,
  createInput,
  createResize,
  createAction,
  createControl,
  parseMessage
} from "./protocol.js";

export const STATE_CONNECTING = "connecting";
export const STATE_LIVE = "live";
export const STATE_RECONNECTING = "reconnecting";
export const STATE_DISCONNECTED = "disconnected";

export class Transport {
  constructor(options = {}) {
    this.clientType = options.clientType || "desktop";
    this.sessionName = options.sessionName || "main";
    this.token = options.token || "";
    this.cols = options.cols || 80;
    this.rows = options.rows || 24;

    this.onOutput = options.onOutput || (() => {});
    this.onStatusChange = options.onStatusChange || (() => {});
    this.onControlChanged = options.onControlChanged || (() => {});
    this.onPanesUpdate = options.onPanesUpdate || (() => {});
    this.onError = options.onError || (() => {});
    this.onAck = options.onAck || (() => {});
    this.onSessionAssigned = options.onSessionAssigned || (() => {});

    this.ws = null;
    this.state = STATE_DISCONNECTED;
    this.reconnectAttempts = 0;
    this.reconnectTimer = null;
    this.pingTimer = null;
    this.isPageVisible = true;
    this.opCounter = 1;

    this.initVisibilityListener();
  }

  initVisibilityListener() {
    if (typeof document !== "undefined" && document.addEventListener) {
      document.addEventListener("visibilitychange", () => {
        this.isPageVisible = !document.hidden;
        if (this.isPageVisible) {
          if (this.state === STATE_DISCONNECTED || this.state === STATE_RECONNECTING) {
            this.reconnectImmediately();
          }
        }
      });
    }
  }

  connect() {
    if (this.ws) {
      try { this.ws.close(); } catch {}
      this.ws = null;
    }

    this.setState(STATE_CONNECTING);

    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    const tokenQuery = this.token ? ("&token=" + encodeURIComponent(this.token)) : "";
    const wsUrl = proto + "//" + location.host + "/ws?client=" + this.clientType +
      "&session=" + encodeURIComponent(this.sessionName) +
      "&cols=" + this.cols + "&rows=" + this.rows + tokenQuery;

    try {
      this.ws = new WebSocket(wsUrl, [PROTOCOL_VERSION]);
    } catch (e) {
      this.ws = new WebSocket(wsUrl);
    }

    this.ws.onopen = () => {
      this.reconnectAttempts = 0;
      this.setState(STATE_LIVE);

      // Send initial hello handshake
      this.ws.send(createHello(this.clientType, this.cols, this.rows));
      this.startPing();
    };

    this.ws.onmessage = (event) => {
      this.handleMessage(event.data);
    };

    this.ws.onclose = () => {
      this.stopPing();
      this.setState(STATE_RECONNECTING);
      this.scheduleReconnect();
    };

    this.ws.onerror = () => {
      try { this.ws.close(); } catch {}
    };
  }

  handleMessage(data) {
    const parsed = parseMessage(data);

    if (parsed.isControl && parsed.message) {
      const msg = parsed.message;
      if (msg.type === "session") {
        if (msg.session) {
          this.sessionName = msg.session;
          this.onSessionAssigned(msg.session);
        }
        if (msg.controller) {
          this.onControlChanged(msg.controller, msg.readonly);
        }
        return;
      }

      if (msg.type === MSG_HELLO) {
        if (msg.session) this.sessionName = msg.session;
        this.onControlChanged(msg.controller, msg.readonly);
        return;
      }

      if (msg.type === MSG_CONTROL) {
        this.onControlChanged(msg.controller, msg.readonly);
        return;
      }

      if (msg.type === MSG_PANES && msg.data) {
        this.onPanesUpdate(msg.data);
        return;
      }

      if (msg.type === MSG_ACK) {
        this.onAck(msg.opId);
        return;
      }

      if (msg.type === MSG_ERROR) {
        this.onError(msg.message);
        return;
      }

      if (msg.type === MSG_PONG) {
        return;
      }
    }

    // Terminal display data
    this.onOutput(data);
  }

  setState(newState) {
    if (this.state !== newState) {
      this.state = newState;
      this.onStatusChange(newState);
    }
  }

  scheduleReconnect() {
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    if (!this.isPageVisible) return; // Wait until tab is visible again

    // Exponential backoff with jitter: 1s, 2s, 4s, max 10s
    this.reconnectAttempts++;
    const baseDelay = Math.min(1000 * Math.pow(1.8, this.reconnectAttempts - 1), 10000);
    const jitter = Math.random() * 400;
    const delay = Math.round(baseDelay + jitter);

    this.reconnectTimer = setTimeout(() => {
      this.connect();
    }, delay);
  }

  reconnectImmediately() {
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectAttempts = 0;
    this.connect();
  }

  startPing() {
    this.stopPing();
    this.pingTimer = setInterval(() => {
      if (this.ws && this.ws.readyState === WebSocket.OPEN) {
        this.ws.send(JSON.stringify({ type: MSG_PING, t: Date.now() }));
      }
    }, 25000);
  }

  stopPing() {
    if (this.pingTimer) {
      clearInterval(this.pingTimer);
      this.pingTimer = null;
    }
  }

  sendInput(data, paneId = null) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      const opId = this.opCounter++;
      this.ws.send(createInput(data, opId, paneId));
      return opId;
    }
    return null;
  }

  sendRaw(data) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(data);
    }
  }

  sendResize(cols, rows) {
    this.cols = cols;
    this.rows = rows;
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(createResize(cols, rows));
    }
  }

  requestControl() {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(createControl("request"));
    }
  }

  releaseControl() {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(createControl("release"));
    }
  }

  sendAction(action, target = null) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(createAction(action, target));
    }
  }
}
