import test from 'node:test';
import assert from 'node:assert/strict';
import {
  PROTOCOL_VERSION,
  MSG_HELLO,
  MSG_INPUT,
  MSG_RESIZE,
  MSG_ACTION,
  MSG_CONTROL,
  parseMessage,
  createHello,
  createInput,
  createResize,
  createAction,
  createControl
} from '../public/app/protocol.js';
import { SessionCoordinator, isMouseWheel, isGarbageResponse } from '../server.js';

test('protocol.js: parseMessage separates control frames and raw input', () => {
  // 1. Valid control frames
  const resizeMsg = createResize(80, 24);
  const p1 = parseMessage(resizeMsg);
  assert.equal(p1.isControl, true);
  assert.equal(p1.message.type, MSG_RESIZE);
  assert.equal(p1.message.cols, 80);
  assert.equal(p1.message.rows, 24);

  const inputMsg = createInput('hello world');
  const p2 = parseMessage(inputMsg);
  assert.equal(p2.isControl, true);
  assert.equal(p2.message.type, MSG_INPUT);
  assert.equal(p2.message.data, 'hello world');

  // 2. Malformed JSON starting with { must be marked isControl to NEVER leak to stdin
  const brokenJson = '{"type": "resize", broken';
  const p3 = parseMessage(brokenJson);
  assert.equal(p3.isControl, true);
  assert.equal(p3.isInvalidControl, true);
  assert.equal(p3.message, null);

  // 3. Raw input not starting with { is raw
  const rawInput = 'ls -la\n';
  const p4 = parseMessage(rawInput);
  assert.equal(p4.isControl, false);
  assert.equal(p4.message, null);
  assert.equal(p4.raw, 'ls -la\n');

  // 4. Binary array buffer is raw
  const p5 = parseMessage(new Uint8Array([1, 2, 3]));
  assert.equal(p5.isControl, false);
  assert.equal(p5.isBinary, true);
});

test('SessionCoordinator: ownership and observer mode', () => {
  const coord = new SessionCoordinator('test-session');
  assert.equal(coord.controller, 'desktop');

  // 1. Desktop client connects
  const desktop = { clientType: 'desktop', ws: { send() {} } };
  coord.addClient(desktop);
  assert.equal(desktop.isController, true);
  assert.equal(desktop.readonly, false);
  assert.equal(coord.controller, 'desktop');

  // 2. Mobile client connects while desktop is active -> starts in observer mode
  const mobile = { clientType: 'mobile', ws: { send() {} } };
  coord.addClient(mobile);
  assert.equal(mobile.isController, false);
  assert.equal(mobile.readonly, true);
  assert.equal(desktop.isController, true);
  assert.equal(desktop.readonly, false);

  // 3. Mobile requests control
  coord.setController('mobile');
  assert.equal(coord.controller, 'mobile');
  assert.equal(mobile.isController, true);
  assert.equal(mobile.readonly, false);
  assert.equal(desktop.isController, false);
  assert.equal(desktop.readonly, true);

  // 4. Release control back to desktop
  coord.setController('desktop');
  assert.equal(coord.controller, 'desktop');
  assert.equal(mobile.isController, false);
  assert.equal(mobile.readonly, true);
  assert.equal(desktop.isController, true);
  assert.equal(desktop.readonly, false);

  // 5. Desktop disconnects -> mobile gets control automatically
  coord.removeClient(desktop);
  assert.equal(coord.controller, 'mobile');
  assert.equal(mobile.isController, true);
  assert.equal(mobile.readonly, false);
});

test('isMouseWheel detects SGR mouse wheel sequences', () => {
  assert.equal(isMouseWheel('\x1b[<64;20;10M'), true);
  assert.equal(isMouseWheel('\x1b[<65;1;1M'), true);
  assert.equal(isMouseWheel('\x1b[<64;1;1M\x1b[<64;1;1M'), true);
  assert.equal(isMouseWheel('\x1b[<0;20;10M'), false);
  assert.equal(isMouseWheel('ls -la\r'), false);
  assert.equal(isMouseWheel('\x1b[A'), false);
});

test('isGarbageResponse identifies probe responses and does not block user input', () => {
  assert.equal(isGarbageResponse('\x1b[>0;276;0c'), true);
  assert.equal(isGarbageResponse('0;276;0c'), true);
  assert.equal(isGarbageResponse('\x1b[?1;2c'), true);
  assert.equal(isGarbageResponse('\x1b[c'), true);
  assert.equal(isGarbageResponse('\x1b[0n'), true);
  assert.equal(isGarbageResponse('\x1b[35;12R'), true);
  assert.equal(isGarbageResponse('\x1b]11;rgb:0000/0000/0000\x07'), true);
  assert.equal(isGarbageResponse('echo hello'), false);
  assert.equal(isGarbageResponse('\x1b[A'), false); // Up arrow
  assert.equal(isGarbageResponse('\x1b[<64;10;10M'), false); // Mouse wheel
});
