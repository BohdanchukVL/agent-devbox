import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { execFile, execFileSync, spawnSync } from 'node:child_process';
import { WebSocketServer } from 'ws';
import pty from 'node-pty';
import Busboy from 'busboy';
import {
  PROTOCOL_VERSION,
  MSG_HELLO,
  MSG_INPUT,
  MSG_RESIZE,
  MSG_ACTION,
  MSG_CONTROL,
  MSG_PANES,
  MSG_STATUS,
  MSG_PING,
  MSG_PONG,
  MSG_ERROR,
  MSG_ACK,
  parseMessage
} from './public/app/protocol.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const PORT = parseInt(process.env.PORT || '7681', 10);
// "auto": in tailscale mode bind the tailnet addresses plus loopback, otherwise loopback only.
const HOST = process.env.HOST || '127.0.0.1';
const AUTH_TOKEN = process.env.DEVBOX_WEB_TOKEN || process.env.AUTH_TOKEN || (process.env.DEVBOX_WEB_TEST ? 'test-secret-token' : '');
const ALLOWED_ORIGIN = process.env.DEVBOX_ALLOWED_ORIGIN || '';
const TAILSCALE_BIN = process.env.DEVBOX_TAILSCALE_BIN || 'tailscale';
// Auth modes:
//   tailscale  the peer is identified by the tailnet (`tailscale whois` on the source
//              address, or the identity headers injected by `tailscale serve`); no secret.
//   token      shared secret via cookie / header / query (the pre-0.4.1 behaviour).
// Default: token when a token is configured, tailscale otherwise.
const AUTH_MODE = (process.env.DEVBOX_WEB_AUTH || (AUTH_TOKEN ? 'token' : 'tailscale')).toLowerCase();

if (AUTH_MODE !== 'token' && AUTH_MODE !== 'tailscale') {
  console.error(`[devbox-web ERROR] DEVBOX_WEB_AUTH must be "tailscale" or "token", got "${AUTH_MODE}".`);
  process.exit(1);
}
if (AUTH_MODE === 'token' && !AUTH_TOKEN) {
  console.error('[devbox-web ERROR] DEVBOX_WEB_TOKEN (or AUTH_TOKEN) environment variable is required in token auth mode. Refusing to start without authentication.');
  process.exit(1);
}

const PUBLIC_DIR = path.join(__dirname, 'public');
const NODE_MODULES = path.join(__dirname, 'node_modules');

function getMimeType(filePath) {
  const ext = path.extname(filePath).toLowerCase();
  const types = {
    '.html': 'text/html; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.js': 'application/javascript; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.svg': 'image/svg+xml',
    '.ico': 'image/x-icon',
    '.woff2': 'font/woff2',
    '.woff': 'font/woff',
    '.ttf': 'font/ttf'
  };
  return types[ext] || 'application/octet-stream';
}

function sanitizeSessionName(name) {
  if (typeof name !== 'string') return 'main';
  const clean = name.trim();
  if (/^[a-zA-Z0-9_-]{1,64}$/.test(clean)) {
    return clean;
  }
  return 'main';
}

function ensureTmuxSession(sessionName) {
  sessionName = sanitizeSessionName(sessionName);
  const check = spawnSync('tmux', ['has-session', '-t', 'main'], { stdio: 'ignore' });
  if (check.status !== 0) {
    const rootDir = fs.existsSync('/workspace') ? '/workspace' : (process.env.HOME || '/home/dev');
    spawnSync('tmux', ['new-session', '-d', '-s', 'main', '-c', rootDir], { stdio: 'ignore' });
  }

  if (sessionName !== 'main') {
    const checkTarget = spawnSync('tmux', ['has-session', '-t', sessionName], { stdio: 'ignore' });
    if (checkTarget.status !== 0) {
      spawnSync('tmux', ['new-session', '-d', '-t', 'main', '-s', sessionName], { stdio: 'ignore' });
    }
  }
}

function getPaneCwd(sessionName) {
  sessionName = sanitizeSessionName(sessionName);
  try {
    const cwd = execFileSync('tmux', ['display-message', '-p', '-t', sessionName, '#{pane_current_path}'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore']
    }).trim();
    if (cwd && fs.existsSync(cwd)) return cwd;
  } catch {}
  return fs.existsSync('/workspace') ? '/workspace' : (process.env.HOME || '/home/dev');
}

function getPaneId(sessionName) {
  sessionName = sanitizeSessionName(sessionName);
  try {
    const paneId = execFileSync('tmux', ['display-message', '-p', '-t', sessionName, '#{pane_id}'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore']
    }).trim();
    if (paneId) return paneId;
  } catch {}
  return sessionName;
}

function isDaResponse(str) {
  return typeof str === 'string' && (str.startsWith('\x1b[>') || str.startsWith('\x1b[?')) && str.endsWith('c');
}

function isMouseWheel(str) {
  return typeof str === 'string' && /^(\x1b\[<6[45];\d+;\d+[Mm])+$/.test(str);
}

function isGarbageResponse(raw) {
  if (typeof raw !== 'string') return false;
  if (isMouseWheel(raw)) return false;
  if (raw === '\x1b[0n' || raw === '0n') return true;
  if (/^\x1b\[[>?=]?[\d;]*c/.test(raw) || /^0;276;0c/.test(raw)) return true;
  if (/^\x1b\[\d+(;\d+)?R/.test(raw)) return true;
  if (/^\x1b\](10|11|12|4);/.test(raw)) return true;
  return false;
}

function isWindowZoomed(sessionName) {
  try {
    const out = execFileSync('tmux', ['display-message', '-p', '-t', sanitizeSessionName(sessionName), '#{window_zoomed_flag}'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore']
    }).trim();
    return out === '1';
  } catch {
    return false;
  }
}

function getPanesInfo(sessionName) {
  sessionName = sanitizeSessionName(sessionName);
  try {
    const winOutput = execFileSync('tmux', [
      'list-windows', '-t', sessionName,
      '-F', '#{window_id}\t#{window_index}\t#{window_name}\t#{window_active}\t#{window_panes}\t#{window_zoomed_flag}'
    ], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();

    const windows = winOutput ? winOutput.split('\n').filter(Boolean).map(line => {
      const parts = line.split('\t');
      return {
        id: parts[0] || '',
        index: parseInt(parts[1], 10) || 1,
        name: parts[2] || '',
        active: parts[3] === '1',
        panesCount: parseInt(parts[4], 10) || 1,
        zoomed: parts[5] === '1'
      };
    }) : [];

    const paneOutput = execFileSync('tmux', [
      'list-panes', '-s', '-t', sessionName,
      '-F', '#{window_id}\t#{pane_id}\t#{pane_index}\t#{pane_title}\t#{pane_current_command}\t#{pane_current_path}\t#{pane_active}'
    ], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();

    const panes = paneOutput ? paneOutput.split('\n').filter(Boolean).map(line => {
      const parts = line.split('\t');
      return {
        windowId: parts[0] || '',
        id: parts[1] || '',
        index: parseInt(parts[2], 10) || 1,
        title: parts[3] || '',
        command: parts[4] || '',
        path: parts[5] || '',
        active: parts[6] === '1'
      };
    }) : [];

    return { ok: true, session: sessionName, windows, panes };
  } catch (err) {
    return { ok: false, error: err.message, session: sessionName, windows: [], panes: [] };
  }
}

class SessionCoordinator {
  constructor(sessionName) {
    this.sessionName = sessionName;
    this.clients = new Set();
    this.controller = 'desktop';
  }

  addClient(client) {
    this.clients.add(client);
    this.recompute();
  }

  removeClient(client) {
    this.clients.delete(client);
    this.recompute();
  }

  recompute() {
    const hasDesktop = Array.from(this.clients).some(c => c.clientType === 'desktop');
    const hasMobile = Array.from(this.clients).some(c => c.clientType === 'mobile');

    if (!hasMobile) {
      this.controller = 'desktop';
    } else if (!hasDesktop) {
      this.controller = 'mobile';
    }
    for (const c of this.clients) {
      c.isController = (c.clientType === this.controller);
      c.readonly = !c.isController;
    }
  }

  setController(newController) {
    this.controller = newController;
    for (const c of this.clients) {
      c.isController = (c.clientType === this.controller);
      c.readonly = !c.isController;
    }
    this.broadcastControl();
  }

  broadcastControl() {
    const msg = JSON.stringify({
      type: 'control',
      controller: this.controller,
      session: this.sessionName
    });
    for (const c of this.clients) {
      if (c.ws && c.ws.readyState === c.ws.OPEN) {
        c.ws.send(msg);
      }
    }
  }
}

const sessionCoordinators = new Map();
function getCoordinator(sessionName) {
  if (!sessionCoordinators.has(sessionName)) {
    sessionCoordinators.set(sessionName, new SessionCoordinator(sessionName));
  }
  return sessionCoordinators.get(sessionName);
}

function isTrustedProxyReq(req) {
  const ip = normalizeIp(req?.socket?.remoteAddress);
  return isLoopback(ip);
}

function isAllowedOrigin(origin, hostHeader, forwardedHost, isTrustedProxy = false, forwardedProto = null, isEncrypted = false) {
  if (!origin) return true; // Direct non-browser requests (curl, CLI, etc.)
  try {
    const originUrl = new URL(origin);
    const originHost = originUrl.host.toLowerCase();
    const originProto = originUrl.protocol.toLowerCase();

    if (ALLOWED_ORIGIN) {
      const allowed = ALLOWED_ORIGIN.split(',').map(s => s.trim().toLowerCase()).filter(Boolean);
      if (allowed.includes(origin.toLowerCase()) || allowed.includes(originHost)) return true;
    }

    const expectedProto = (isTrustedProxy && forwardedProto ? forwardedProto : (isEncrypted ? 'https' : 'http')).toLowerCase().replace(/:$/, '') + ':';

    // Forwarded host is ONLY trusted when request arrives via local reverse proxy (e.g. Tailscale Serve on loopback)
    if (isTrustedProxy && forwardedHost) {
      if (originHost === forwardedHost.toLowerCase() && originProto === expectedProto) {
        return true;
      }
    }

    // Direct match: scheme, host, and port must match exactly
    if (hostHeader && originHost === hostHeader.toLowerCase()) {
      if (originProto === expectedProto) {
        return true;
      }
    }
  } catch {}
  return false;
}

function safeTokenCompare(input) {
  if (typeof input !== 'string' || !input || !AUTH_TOKEN) return false;
  const bufA = Buffer.from(input);
  const bufB = Buffer.from(AUTH_TOKEN);
  if (bufA.length !== bufB.length) return false;
  return crypto.timingSafeEqual(bufA, bufB);
}

function parseCookies(cookieHeader) {
  const list = {};
  if (!cookieHeader) return list;
  cookieHeader.split(';').forEach(cookie => {
    const parts = cookie.split('=');
    const name = parts[0]?.trim();
    if (!name) return;
    const value = parts.slice(1).join('=').trim();
    try {
      list[name] = decodeURIComponent(value);
    } catch {
      list[name] = value;
    }
  });
  return list;
}

// Shared-secret check (token auth mode).
function checkAuth(req, url) {
  const authHeader = req.headers['authorization'] || '';
  if (authHeader.startsWith('Bearer ')) {
    if (safeTokenCompare(authHeader.slice(7))) return true;
  } else if (safeTokenCompare(authHeader)) {
    return true;
  }
  const customHeader = req.headers['x-devbox-token'] || '';
  if (safeTokenCompare(customHeader)) return true;

  const cookies = parseCookies(req.headers['cookie']);
  if (cookies['devbox_token'] && safeTokenCompare(cookies['devbox_token'])) {
    return true;
  }

  const tokenQuery = url.searchParams.get('token');
  if (tokenQuery && safeTokenCompare(tokenQuery)) return true;

  return false;
}

// ── Tailnet identity (tailscale auth mode) ────────────────────────────────────

const WHOIS_TTL_MS = 60 * 1000;
const STATUS_TTL_MS = 5 * 60 * 1000;
const whoisCache = new Map();
let statusCache = { at: 0, self: null };

function tailscaleJson(args, timeout = 3000) {
  return new Promise(resolve => {
    execFile(TAILSCALE_BIN, args, { timeout, maxBuffer: 1024 * 1024 }, (err, stdout) => {
      if (err) return resolve(null);
      try {
        resolve(JSON.parse(stdout));
      } catch {
        resolve(null);
      }
    });
  });
}

function parseSelf(status) {
  if (!status || typeof status !== 'object') return null;
  const self = status.Self || {};
  return {
    backendState: status.BackendState || '',
    ips: Array.isArray(self.TailscaleIPs) ? self.TailscaleIPs.map(String) : [],
    dnsName: String(self.DNSName || '').replace(/\.$/, '').toLowerCase(),
    hostName: String(self.HostName || '').toLowerCase()
  };
}

function tailscaleSelfSync() {
  try {
    const out = execFileSync(TAILSCALE_BIN, ['status', '--json'], {
      encoding: 'utf8',
      timeout: 5000,
      stdio: ['ignore', 'pipe', 'ignore']
    });
    const self = parseSelf(JSON.parse(out));
    if (self) statusCache = { at: Date.now(), self };
    return self;
  } catch {
    return null;
  }
}

async function tailscaleSelf() {
  if (statusCache.self && Date.now() - statusCache.at < STATUS_TTL_MS) return statusCache.self;
  const self = parseSelf(await tailscaleJson(['status', '--json']));
  if (self) statusCache = { at: Date.now(), self };
  return self || statusCache.self;
}

function normalizeIp(addr) {
  let ip = String(addr || '').trim();
  if (ip.startsWith('::ffff:')) ip = ip.slice(7);
  const zone = ip.indexOf('%');
  if (zone !== -1) ip = ip.slice(0, zone);
  return ip;
}

function isLoopback(ip) {
  return ip === '::1' || ip.startsWith('127.');
}

// Host header → hostname (no port, no IPv6 brackets), lower-cased.
function hostnameOf(hostHeader) {
  const raw = String(hostHeader || '').trim().toLowerCase();
  if (!raw) return '';
  if (raw.startsWith('[')) {
    const end = raw.indexOf(']');
    return end === -1 ? '' : raw.slice(1, end);
  }
  const colon = raw.indexOf(':');
  if (colon !== -1 && raw.indexOf(':', colon + 1) === -1) return raw.slice(0, colon);
  return raw; // bare IPv6 without brackets or plain name
}

function envList(name) {
  return String(process.env[name] || '')
    .split(',')
    .map(s => s.trim().toLowerCase())
    .filter(Boolean);
}

// DNS-rebinding guard for tailscale mode: only names/addresses this node answers to.
async function isAllowedHost(hostHeader) {
  const name = hostnameOf(hostHeader);
  if (!name) return false;
  if (name === 'localhost' || name === '127.0.0.1' || name === '::1') return true;
  if (envList('DEVBOX_ALLOWED_HOSTS').includes(name)) return true;
  const self = await tailscaleSelf();
  if (!self) return false;
  if (self.ips.map(ip => ip.toLowerCase()).includes(name)) return true;
  if (self.dnsName && name === self.dnsName) return true;
  if (self.hostName && name === self.hostName) return true; // MagicDNS short name
  return false;
}

async function whois(ip) {
  const cached = whoisCache.get(ip);
  if (cached && Date.now() - cached.at < WHOIS_TTL_MS) return cached.identity;
  const data = await tailscaleJson(['whois', '--json', ip]);
  let identity = null;
  if (data && typeof data === 'object') {
    const profile = data.UserProfile || {};
    const node = data.Node || {};
    identity = {
      login: String(profile.LoginName || ''),
      name: String(profile.DisplayName || ''),
      node: String(node.Name || '').replace(/\.$/, ''),
      tagged: Array.isArray(node.Tags) && node.Tags.length > 0,
      via: 'whois'
    };
  }
  whoisCache.set(ip, { at: Date.now(), identity });
  return identity;
}

// Who is on the other end of this connection, according to the tailnet.
async function resolveIdentity(req) {
  const remote = normalizeIp(req.socket?.remoteAddress);
  if (!remote) return null;
  if (isLoopback(remote)) {
    // `tailscale serve` terminates the connection locally and forwards the identity
    // in headers. Anything else on loopback (ssh -L, local processes) carries no identity.
    const login = req.headers['tailscale-user-login'];
    if (!login) return null;
    return {
      login: String(login),
      name: String(req.headers['tailscale-user-name'] || ''),
      node: '',
      tagged: false,
      via: 'serve'
    };
  }
  return whois(remote);
}

// Humans only by default; DEVBOX_WEB_USERS narrows it to specific logins.
function identityAllowed(identity) {
  if (!identity || identity.tagged) return false;
  const login = String(identity.login || '').toLowerCase();
  if (!login || login === 'tagged-devices') return false;
  const users = envList('DEVBOX_WEB_USERS');
  if (users.length) return users.includes(login);
  return true;
}

async function authorize(req, url) {
  if (AUTH_MODE === 'token') {
    return { ok: checkAuth(req, url), identity: null };
  }
  const identity = await resolveIdentity(req);
  return { ok: identityAllowed(identity), identity };
}

const UNAUTHORIZED_MESSAGE = AUTH_MODE === 'token'
  ? 'Unauthorized: invalid or missing auth token'
  : 'Unauthorized: no tailnet identity for this connection';

// ── HTTP ──────────────────────────────────────────────────────────────────────

async function handleRequest(req, res) {
  const hostHeader = req.headers.host || 'localhost';
  const forwardedHost = req.headers['x-forwarded-host'];
  const url = new URL(req.url, `http://${hostHeader}`);
  const pathname = url.pathname;
  const origin = req.headers.origin;

  if (AUTH_MODE === 'tailscale' && !(await isAllowedHost(hostHeader))) {
    res.writeHead(421, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Misdirected: unexpected Host header' }));
    return;
  }

  if (AUTH_MODE === 'token' && (pathname === '/' || pathname === '/index.html') && url.searchParams.has('token')) {
    const tokenParam = url.searchParams.get('token');
    if (safeTokenCompare(tokenParam)) {
      url.searchParams.delete('token');
      const cleanSearch = url.searchParams.toString();
      const redirectTarget = pathname + (cleanSearch ? `?${cleanSearch}` : '');
      res.writeHead(302, {
        'Set-Cookie': `devbox_token=${encodeURIComponent(AUTH_TOKEN)}; Path=/; HttpOnly; SameSite=Strict`,
        'Location': redirectTarget
      });
      res.end();
      return;
    }
  }

  const trusted = isTrustedProxyReq(req);
  const forwardedProto = trusted ? req.headers['x-forwarded-proto'] : null;
  const isEncrypted = Boolean(req.socket?.encrypted);

  if (origin && isAllowedOrigin(origin, hostHeader, forwardedHost, trusted, forwardedProto, isEncrypted)) {
    res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
    res.setHeader('Access-Control-Allow-Credentials', 'true');
  }

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  if (req.method === 'POST' && origin && !isAllowedOrigin(origin, hostHeader, forwardedHost, trusted, forwardedProto, isEncrypted)) {
    res.writeHead(403, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Forbidden: cross-origin POST not allowed' }));
    return;
  }

  let identity = null;
  if (pathname.startsWith('/api/')) {
    const auth = await authorize(req, url);
    if (!auth.ok) {
      res.writeHead(401, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: UNAUTHORIZED_MESSAGE }));
      return;
    }
    identity = auth.identity;
  }

  if (req.method === 'POST' && pathname === '/api/upload') {
    const session = sanitizeSessionName(url.searchParams.get('session') || 'main');
    ensureTmuxSession(session);
    const cwd = getPaneCwd(session);
    const targetPane = getPaneId(session);

    const isProject = cwd.startsWith('/workspace') || fs.existsSync(path.join(cwd, '.git'));
    const inboxDir = isProject
      ? path.join(cwd, '.devbox-inbox')
      : path.join(process.env.HOME || '/home/dev', '.devbox', 'inbox');

    try {
      fs.mkdirSync(inboxDir, { recursive: true });
    } catch (err) {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: `Cannot create inbox directory: ${err.message}` }));
      return;
    }

    let busboy;
    try {
      busboy = Busboy({ headers: req.headers, limits: { fileSize: 100 * 1024 * 1024, files: 10 } });
    } catch (err) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: `Invalid multipart request: ${err.message}` }));
      return;
    }

    let responded = false;
    const tempFiles = [];

    const cleanupTempFiles = () => {
      for (const tempPath of tempFiles) {
        try {
          if (fs.existsSync(tempPath)) fs.unlinkSync(tempPath);
        } catch {}
      }
    };

    const fail = (statusCode, message) => {
      if (responded) return;
      responded = true;
      cleanupTempFiles();
      try {
        req.unpipe(busboy);
        req.resume();
      } catch {}
      res.writeHead(statusCode, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: message }));
    };

    busboy.on('error', (err) => {
      fail(400, `Upload parsing error: ${err.message}`);
    });

    req.on('error', (err) => {
      fail(400, `Request error: ${err.message}`);
    });

    let uploadedFile = null;
    const filePromises = [];

    busboy.on('file', (name, file, info) => {
      const { filename } = info;
      if (!filename) {
        file.resume();
        return;
      }

      // POSIX NAME_MAX is 255 bytes. Ensure total destName and .destName.tmp do not exceed this limit.
      const rawBase = path.basename(filename).replace(/[^a-zA-Z0-9._-]/g, '_') || 'uploaded_file';
      const ext = path.extname(rawBase);
      const nameWithoutExt = ext ? rawBase.slice(0, -ext.length) : rawBase;
      const maxBaseLen = Math.max(1, 200 - ext.length);
      const safeBase = (nameWithoutExt.length > maxBaseLen ? nameWithoutExt.slice(0, maxBaseLen) : nameWithoutExt) + ext;

      const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14);
      const uid = crypto.randomBytes(4).toString('hex');
      const destName = `${stamp}-${uid}-${safeBase}`;
      const destPath = path.join(inboxDir, destName);
      const tempPath = path.join(inboxDir, `.${destName}.tmp`);
      tempFiles.push(tempPath);

      let fileError = null;
      let writeStream = null;

      file.on('limit', () => {
        fileError = new Error('File size limit exceeded (max 100MB)');
        fail(400, fileError.message);
      });
      file.on('error', (err) => {
        fileError = err;
        fail(400, `File stream error: ${err.message}`);
      });

      const p = new Promise((resolve, reject) => {
        try {
          writeStream = fs.createWriteStream(tempPath);
        } catch (err) {
          return reject(err);
        }

        writeStream.on('error', (err) => {
          reject(err);
        });

        file.pipe(writeStream);

        writeStream.on('finish', () => {
          if (fileError) {
            return reject(fileError);
          }
          if (file.truncated) {
            return reject(new Error('File truncated: maximum size 100MB exceeded'));
          }

          try {
            fs.renameSync(tempPath, destPath);
          } catch (err) {
            return reject(err);
          }

          const relativePath = isProject
            ? `.devbox-inbox/${destName}`
            : destPath;

          uploadedFile = {
            filename: destName,
            path: relativePath,
            fullPath: destPath
          };

          let inserted = false;
          try {
            execFileSync('tmux', ['send-keys', '-t', targetPane, '-l', `${relativePath} `]);
            inserted = true;
          } catch (e) {
            console.error(`[upload] failed to send-keys to ${targetPane}:`, e.message);
          }
          uploadedFile.inserted = inserted;
          resolve();
        });
      });

      // Immediately handle rejection so write errors before busboy.finish never crash the process
      p.catch((err) => {
        try {
          file.unpipe();
          file.resume();
        } catch {}
        if (writeStream) {
          try { writeStream.destroy(); } catch {}
        }
        fail(500, `Storage error: ${err.message}`);
      });

      filePromises.push(p);
    });

    busboy.on('finish', async () => {
      if (responded) return;
      try {
        await Promise.all(filePromises);
      } catch (err) {
        return fail(500, err.message);
      }

      if (responded) return;
      if (!uploadedFile) {
        return fail(400, 'No file received');
      }

      responded = true;
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, file: uploadedFile }));
    });

    req.pipe(busboy);
    return;
  }

  if (req.method === 'POST' && pathname === '/api/action') {
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      try {
        const data = JSON.parse(body || '{}');
        const session = sanitizeSessionName(data.session || 'main');
        ensureTmuxSession(session);

        if (data.action === 'zoom') {
          spawnSync('tmux', ['resize-pane', '-Z', '-t', session]);
        } else if (data.action === 'next-window') {
          spawnSync('tmux', ['next-window', '-t', session]);
        } else if (data.action === 'prev-window') {
          spawnSync('tmux', ['previous-window', '-t', session]);
        } else if (data.action === 'select-pane' && data.target) {
          const targetPane = String(data.target).replace(/[^a-zA-Z0-9_%-]/g, '');
          const wasZoomed = isWindowZoomed(session) || data.client === 'mobile';
          spawnSync('tmux', ['select-pane', '-t', targetPane]);
          if (wasZoomed) {
            spawnSync('tmux', ['resize-pane', '-Z', '-t', targetPane]);
          }
        } else if (data.action === 'select-window' && data.target) {
          const targetWin = String(data.target).replace(/[^a-zA-Z0-9_%-]/g, '');
          const wasZoomed = isWindowZoomed(session) || data.client === 'mobile';
          spawnSync('tmux', ['select-window', '-t', targetWin]);
          if (wasZoomed) {
            spawnSync('tmux', ['resize-pane', '-Z', '-t', session]);
          }
        } else if (data.action === 'take-control') {
          const coordinator = getCoordinator(session);
          coordinator.setController(data.client === 'mobile' ? 'mobile' : 'desktop');
        } else if (data.action === 'release-control') {
          const coordinator = getCoordinator(session);
          coordinator.setController('desktop');
        }
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      } catch (err) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: err.message }));
      }
    });
    return;
  }

  if (req.method === 'GET' && pathname === '/api/panes') {
    const session = sanitizeSessionName(url.searchParams.get('session') || 'main');
    const info = getPanesInfo(session);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(info));
    return;
  }

  if (req.method === 'GET' && pathname === '/api/status') {
    const session = sanitizeSessionName(url.searchParams.get('session') || 'main');
    let cwd = '';
    try {
      cwd = getPaneCwd(session);
    } catch {}
    const coordinator = getCoordinator(session);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      ok: true,
      session,
      cwd,
      controller: coordinator.controller,
      node: process.version,
      auth: AUTH_MODE,
      user: identity ? identity.login : null
    }));
    return;
  }

  let targetPath;
  if (pathname === '/' || pathname === '/index.html') {
    targetPath = path.join(PUBLIC_DIR, 'index.html');
  } else if (pathname.startsWith('/vendor/xterm/')) {
    const rel = pathname.replace('/vendor/xterm/', '');
    const modernPath = path.join(NODE_MODULES, '@xterm', 'xterm', rel);
    const legacyPath = path.join(NODE_MODULES, 'xterm', rel);
    targetPath = fs.existsSync(modernPath) ? modernPath : legacyPath;
  } else if (pathname.startsWith('/vendor/addon-fit/')) {
    targetPath = path.join(NODE_MODULES, '@xterm', 'addon-fit', pathname.replace('/vendor/addon-fit/', ''));
  } else if (pathname.startsWith('/vendor/addon-webgl/')) {
    targetPath = path.join(NODE_MODULES, '@xterm', 'addon-webgl', pathname.replace('/vendor/addon-webgl/', ''));
  } else {
    const safePath = path.normalize(pathname).replace(/^(\.\.[\/\\])+/, '');
    targetPath = path.join(PUBLIC_DIR, safePath);
  }

  if (fs.existsSync(targetPath) && fs.statSync(targetPath).isFile()) {
    res.writeHead(200, { 'Content-Type': getMimeType(targetPath) });
    fs.createReadStream(targetPath).pipe(res);
  } else {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not found');
  }
}

function requestListener(req, res) {
  handleRequest(req, res).catch(err => {
    console.error('[devbox-web] request failed:', err);
    if (!res.headersSent) {
      res.writeHead(500, { 'Content-Type': 'application/json' });
    }
    res.end(JSON.stringify({ error: 'Internal error' }));
  });
}

// ── WebSocket ─────────────────────────────────────────────────────────────────

const wss = new WebSocketServer({
  noServer: true,
  handleProtocols: (protocols) => {
    if (protocols) {
      if (typeof protocols.has === 'function' && protocols.has('devbox-terminal.v2')) {
        return 'devbox-terminal.v2';
      }
      if (Array.isArray(protocols) && protocols.includes('devbox-terminal.v2')) {
        return 'devbox-terminal.v2';
      }
    }
    return false;
  }
});

function rejectUpgrade(socket, code, reason) {
  try {
    socket.write(`HTTP/1.1 ${code} ${reason}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
  } catch {}
  socket.destroy();
}

async function handleUpgrade(req, socket, head) {
  const hostHeader = req.headers.host || 'localhost';
  const forwardedHost = req.headers['x-forwarded-host'];
  const url = new URL(req.url, `http://${hostHeader}`);
  const origin = req.headers.origin;
  const trusted = isTrustedProxyReq(req);
  const forwardedProto = trusted ? req.headers['x-forwarded-proto'] : null;
  const isEncrypted = Boolean(req.socket?.encrypted);

  if (AUTH_MODE === 'tailscale' && !(await isAllowedHost(hostHeader))) {
    console.warn(`[ws] rejected connection: unexpected host "${hostHeader}"`);
    rejectUpgrade(socket, 421, 'Misdirected Request');
    return;
  }
  if (origin && !isAllowedOrigin(origin, hostHeader, forwardedHost, trusted, forwardedProto, isEncrypted)) {
    console.warn(`[ws] rejected connection: unauthorized origin "${origin}" for host "${hostHeader}" (forwarded: "${forwardedHost || 'none'}")`);
    rejectUpgrade(socket, 403, 'Forbidden');
    return;
  }
  const auth = await authorize(req, url);
  if (!auth.ok) {
    console.warn(`[ws] rejected connection: ${UNAUTHORIZED_MESSAGE}`);
    rejectUpgrade(socket, 401, 'Unauthorized');
    return;
  }
  req.identity = auth.identity;
  wss.handleUpgrade(req, socket, head, ws => wss.emit('connection', ws, req));
}

function upgradeListener(req, socket, head) {
  handleUpgrade(req, socket, head).catch(err => {
    console.error('[ws] upgrade failed:', err);
    rejectUpgrade(socket, 500, 'Internal Server Error');
  });
}

const server = http.createServer(requestListener);
server.on('upgrade', upgradeListener);

const pingInterval = setInterval(() => {
  wss.clients.forEach(ws => {
    if (ws.isAlive === false) {
      return ws.terminate();
    }
    ws.isAlive = false;
    ws.ping();
  });
}, 30000);
pingInterval.unref();

wss.on('close', () => {
  clearInterval(pingInterval);
});

const activeSessionClients = new Map();

wss.on('connection', (ws, req) => {
  const hostHeader = req.headers.host || 'localhost';
  const url = new URL(req.url, `http://${hostHeader}`);
  const who = req.identity ? ` as ${req.identity.login} (${req.identity.via})` : '';

  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });

  const clientType = url.searchParams.get('client') === 'mobile' ? 'mobile' : 'desktop';
  const cols = parseInt(url.searchParams.get('cols') || '120', 10);
  const rows = parseInt(url.searchParams.get('rows') || '30', 10);
  const customSession = url.searchParams.get('session');

  let sessionName;
  let isEphemeral = false;

  if (customSession && customSession !== 'main' && customSession !== 'main-web' && customSession !== 'main-mobile') {
    sessionName = sanitizeSessionName(customSession);
    ensureTmuxSession(sessionName);
    isEphemeral = sessionName.startsWith('web-');
  } else {
    const clientId = crypto.randomBytes(4).toString('hex');
    sessionName = sanitizeSessionName(`web-${clientType}-${clientId}`);
    ensureTmuxSession(sessionName);
    isEphemeral = true;
  }

  activeSessionClients.set(sessionName, (activeSessionClients.get(sessionName) || 0) + 1);

  console.log(`[ws] client connected (${clientType})${who} -> session "${sessionName}" [${cols}x${rows}]`);

  const term = pty.spawn('tmux', ['attach-session', '-t', sessionName], {
    name: 'xterm-256color',
    cols: Math.max(cols, 20),
    rows: Math.max(rows, 10),
    cwd: process.env.HOME || '/home/dev',
    env: {
      ...process.env,
      TERM: 'xterm-256color',
      COLORTERM: 'truecolor'
    }
  });

  const clientState = {
    ws,
    clientType,
    sessionName,
    term,
    isController: false,
    readonly: false
  };

  const coordinator = getCoordinator(sessionName);
  coordinator.addClient(clientState);

  ws.send(JSON.stringify({
    type: 'session',
    session: sessionName,
    controller: coordinator.controller,
    readonly: clientState.readonly,
    protocol: PROTOCOL_VERSION
  }));

  term.onData(data => {
    if (ws.readyState === ws.OPEN) {
      ws.send(data);
    }
  });

  ws.on('message', message => {
    const raw = message.toString();
    const parsed = parseMessage(raw);

    if (parsed.isControl) {
      if (parsed.message) {
        const msg = parsed.message;
        try {
          if (msg.type === MSG_HELLO) {
            ws.send(JSON.stringify({
              type: MSG_HELLO,
              session: sessionName,
              paneId: getPaneId(sessionName),
              controller: coordinator.controller,
              readonly: clientState.readonly,
              cols: term.cols,
              rows: term.rows,
              protocol: PROTOCOL_VERSION
            }));
          } else if (msg.type === MSG_RESIZE) {
            if (clientState.readonly) {
              // Observer mode: do NOT alter shared terminal geometry!
              return;
            }
            const c = Math.max(parseInt(msg.cols, 10) || 20, 10);
            const r = Math.max(parseInt(msg.rows, 10) || 10, 5);
            term.resize(c, r);
          } else if (msg.type === MSG_INPUT) {
            if (clientState.readonly) {
              ws.send(JSON.stringify({
                type: MSG_ERROR,
                message: 'Режим перегляду: увімкніть керування для введення'
              }));
              return;
            }
            if (typeof msg.data === 'string') {
              term.write(msg.data);
              if (msg.opId) {
                ws.send(JSON.stringify({ type: MSG_ACK, opId: msg.opId }));
              }
            }
          } else if (msg.type === MSG_CONTROL) {
            if (msg.action === 'request') {
              coordinator.setController(clientState.clientType);
            } else if (msg.action === 'release') {
              coordinator.setController('desktop');
            }
          } else if (msg.type === MSG_ACTION) {
            if (msg.action === 'zoom') {
              spawnSync('tmux', ['resize-pane', '-Z', '-t', sessionName]);
            } else if (msg.action === 'select-pane' && msg.target) {
              const targetPane = String(msg.target).replace(/[^a-zA-Z0-9_%-]/g, '');
              const wasZoomed = isWindowZoomed(sessionName) || clientState.clientType === 'mobile';
              spawnSync('tmux', ['select-pane', '-t', targetPane]);
              if (wasZoomed) {
                spawnSync('tmux', ['resize-pane', '-Z', '-t', targetPane]);
              }
            } else if (msg.action === 'select-window' && msg.target) {
              const targetWin = String(msg.target).replace(/[^a-zA-Z0-9_%-]/g, '');
              const wasZoomed = isWindowZoomed(sessionName) || clientState.clientType === 'mobile';
              spawnSync('tmux', ['select-window', '-t', targetWin]);
              if (wasZoomed) {
                spawnSync('tmux', ['resize-pane', '-Z', '-t', sessionName]);
              }
            }
            ws.send(JSON.stringify({
              type: MSG_PANES,
              data: getPanesInfo(sessionName)
            }));
          } else if (msg.type === MSG_PING) {
            ws.send(JSON.stringify({ type: MSG_PONG, t: Date.now() }));
          }
        } catch (err) {
          console.warn('[ws] control message error:', err.message);
          ws.send(JSON.stringify({ type: MSG_ERROR, message: err.message }));
        }
      } else {
        console.warn('[ws] dropped invalid control frame');
      }
      return; // CRITICAL: NEVER write control frames to stdin!
    }

    // Filter out client Device Attributes and probe responses
    if (isGarbageResponse(raw)) {
      return;
    }

    const cleanRaw = raw.replace(/\x1b\[[>?=]?[\d;]+c/g, '')
                        .replace(/0;276;0c/g, '')
                        .replace(/\x1b\[\d+(;\d+)?R/g, '')
                        .replace(/\x1b\[0n/g, '');
    if (!cleanRaw) {
      return;
    }

    // Direct text / keystrokes: only allow if not in readonly observer mode,
    // but allow mouse wheel scrolling so observers can navigate history cleanly.
    if (clientState.readonly) {
      if (!isMouseWheel(cleanRaw)) {
        return;
      }
    }

    term.write(cleanRaw);
  });

  ws.on('close', () => {
    console.log(`[ws] client disconnected from session "${sessionName}"`);
    try {
      term.kill();
    } catch {}
    coordinator.removeClient(clientState);
    if (coordinator.clients.size === 0) {
      sessionCoordinators.delete(sessionName);
    }
    const remaining = (activeSessionClients.get(sessionName) || 1) - 1;
    if (remaining <= 0) {
      activeSessionClients.delete(sessionName);
      if (isEphemeral) {
        setTimeout(() => {
          if (!activeSessionClients.has(sessionName)) {
            spawnSync('tmux', ['kill-session', '-t', sessionName], { stdio: 'ignore' });
          }
        }, 3000);
      }
    } else {
      activeSessionClients.set(sessionName, remaining);
    }
  });

  term.onExit(() => {
    ws.close();
  });
});

// ── Listening ─────────────────────────────────────────────────────────────────

// Addresses to bind. In tailscale mode with HOST=auto: every tailnet address of this
// node plus loopback (for `tailscale serve` and ssh -L); otherwise loopback only.
function listenAddresses() {
  if (HOST !== 'auto') return [HOST];
  if (AUTH_MODE !== 'tailscale') return ['127.0.0.1'];
  const self = tailscaleSelfSync();
  if (!self || self.backendState !== 'Running' || self.ips.length === 0) {
    throw new Error('tailscale is not running or has no address yet (HOST=auto needs a joined tailnet)');
  }
  return [...self.ips, '127.0.0.1'];
}

function startListening() {
  if (AUTH_MODE === 'tailscale' && !tailscaleSelfSync()) {
    console.error(`[devbox-web ERROR] auth mode "tailscale" but "${TAILSCALE_BIN} status --json" is not available. Refusing to start.`);
    process.exit(1);
  }
  let addresses;
  try {
    addresses = listenAddresses();
  } catch (err) {
    console.error(`[devbox-web ERROR] ${err.message}`);
    process.exit(1);
  }
  addresses.forEach((address, index) => {
    const srv = index === 0 ? server : http.createServer(requestListener);
    if (index !== 0) srv.on('upgrade', upgradeListener);
    srv.on('error', err => {
      console.error(`[devbox-web ERROR] cannot listen on ${address}:${PORT}: ${err.message}`);
      process.exit(1);
    });
    srv.listen(PORT, address, () => {
      const shown = address.includes(':') ? `[${address}]` : address;
      console.log(`[devbox-web] server listening at http://${shown}:${PORT} (auth: ${AUTH_MODE})`);
    });
  });
}

export {
  server,
  wss,
  parseCookies,
  checkAuth,
  isAllowedOrigin,
  safeTokenCompare,
  AUTH_MODE,
  hostnameOf,
  isAllowedHost,
  resolveIdentity,
  identityAllowed,
  authorize,
  isDaResponse,
  isMouseWheel,
  isGarbageResponse,
  isWindowZoomed,
  getPanesInfo,
  SessionCoordinator,
  sessionCoordinators,
  getCoordinator
};

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  startListening();
}
