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
    this.onAckCallback = options.onAck || (() => {});
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

    if (this.ws) {
      const oldWs = this.ws;
      oldWs.onopen = null;
      oldWs.onmessage = null;
      oldWs.onclose = null;
      oldWs.onerror = null;
      try { oldWs.close(); } catch {}
      this.ws = null;
    }

    let socket;
    try {
      socket = new WebSocket(wsUrl, [PROTOCOL_VERSION]);
    } catch (e) {
      socket = new WebSocket(wsUrl);
    }

    this.ws = socket;
    socket.binaryType = "arraybuffer";

    socket.onopen = () => {
      if (this.ws !== socket) return;
      this.reconnectAttempts = 0;
      this.setState(STATE_LIVE);

      // Send initial hello handshake
      socket.send(createHello(this.clientType, this.cols, this.rows));
      this.startPing();
    };

    socket.onmessage = (event) => {
      if (this.ws !== socket) return;
      this.handleMessage(event.data);
    };

    socket.onclose = () => {
      if (this.ws !== socket) return;
      this.stopPing();
      this.setState(STATE_RECONNECTING);
      this.scheduleReconnect();
    };

    socket.onerror = () => {
      if (this.ws !== socket) return;
      try { socket.close(); } catch {}
    };
  }

  handleMessage(data) {
    if (data instanceof ArrayBuffer) {
      this.onOutput(new Uint8Array(data));
      return;
    }

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
        this.onError(msg.message, msg.opId);
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
      if (typeof data === 'string') {
        this.ws.send(new TextEncoder().encode(data));
      } else {
        this.ws.send(data);
      }
    }
  }

  onAck(opId) {
    if (this.onAckCallback) {
      this.onAckCallback(opId);
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
