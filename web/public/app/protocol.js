/**
 * devbox-terminal.v2 WebSocket protocol definition
 * Shared between client and server
 */

export const PROTOCOL_VERSION = 'devbox-terminal.v2';

export const MSG_HELLO = 'hello';
export const MSG_INPUT = 'input';
export const MSG_RESIZE = 'resize';
export const MSG_ACTION = 'action';
export const MSG_CONTROL = 'control';
export const MSG_PANES = 'panes';
export const MSG_STATUS = 'status';
export const MSG_PING = 'ping';
export const MSG_PONG = 'pong';
export const MSG_ERROR = 'error';
export const MSG_ACK = 'ack';

export function createHello(clientType = 'desktop', cols = 80, rows = 24, epoch = Date.now()) {
  return JSON.stringify({
    type: MSG_HELLO,
    client: clientType,
    cols: Math.max(cols, 10),
    rows: Math.max(rows, 5),
    epoch
  });
}

export function createInput(data, opId = null, paneId = null) {
  const msg = { type: MSG_INPUT, data };
  if (opId !== null) msg.opId = opId;
  if (paneId !== null) msg.paneId = paneId;
  return JSON.stringify(msg);
}

export function createResize(cols, rows) {
  return JSON.stringify({
    type: MSG_RESIZE,
    cols: Math.max(parseInt(cols, 10) || 20, 10),
    rows: Math.max(parseInt(rows, 10) || 10, 5)
  });
}

export function createAction(action, target = null) {
  const msg = { type: MSG_ACTION, action };
  if (target) msg.target = target;
  return JSON.stringify(msg);
}

export function createControl(action) {
  return JSON.stringify({ type: MSG_CONTROL, action });
}

export function createPing() {
  return JSON.stringify({ type: MSG_PING, t: Date.now() });
}

export function parseMessage(data) {
  if (typeof data !== 'string') {
    if (data instanceof ArrayBuffer || ArrayBuffer.isView(data)) {
      return { isControl: false, message: null, raw: data, isBinary: true };
    }
    data = String(data);
  }

  const trimmed = data.trim();
  if (trimmed.startsWith('{')) {
    if (trimmed.endsWith('}')) {
      try {
        const parsed = JSON.parse(trimmed);
        if (parsed && typeof parsed.type === 'string') {
          return { isControl: true, message: parsed, raw: data, isBinary: false };
        }
      } catch {}
    }
    // If it started with { but failed parsing or has no type, it is considered an invalid control frame
    return { isControl: true, message: null, isInvalidControl: true, raw: data, isBinary: false };
  }

  return { isControl: false, message: null, raw: data, isBinary: false };
}
