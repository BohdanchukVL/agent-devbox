import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execSync, spawn } from 'node:child_process';
import { WebSocketServer } from 'ws';
import pty from 'node-pty';
import Busboy from 'busboy';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const PORT = parseInt(process.env.PORT || '7681', 10);
const HOST = process.env.HOST || '127.0.0.1';
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

function ensureTmuxSession(sessionName) {
  try {
    execSync('tmux has-session -t main 2>/dev/null');
  } catch {
    const rootDir = fs.existsSync('/workspace') ? '/workspace' : (process.env.HOME || '/home/dev');
    execSync(`tmux new-session -d -s main -c "${rootDir}"`);
  }

  if (sessionName !== 'main') {
    try {
      execSync(`tmux has-session -t "${sessionName}" 2>/dev/null`);
    } catch {
      execSync(`tmux new-session -d -t main -s "${sessionName}"`);
    }
  }
}

function getPaneCwd(sessionName) {
  try {
    const cwd = execSync(`tmux display-message -p -t "${sessionName}" '#{pane_current_path}' 2>/dev/null`, {
      encoding: 'utf8'
    }).trim();
    if (cwd && fs.existsSync(cwd)) return cwd;
  } catch {}
  return fs.existsSync('/workspace') ? '/workspace' : (process.env.HOME || '/home/dev');
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const pathname = url.pathname;

  // CORS headers for Tailnet access
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  // 1. Upload API
  if (req.method === 'POST' && pathname === '/api/upload') {
    const session = url.searchParams.get('session') || 'main-web';
    ensureTmuxSession(session);
    const cwd = getPaneCwd(session);

    const busboy = Busboy({ headers: req.headers, limits: { fileSize: 100 * 1024 * 1024 } });
    let uploadedFile = null;
    const filePromises = [];

    // Use .devbox-inbox in cwd if inside /workspace or git project, else ~/.devbox/inbox
    const isProject = cwd.startsWith('/workspace') || fs.existsSync(path.join(cwd, '.git'));
    const inboxDir = isProject
      ? path.join(cwd, '.devbox-inbox')
      : path.join(process.env.HOME || '/home/dev', '.devbox', 'inbox');

    fs.mkdirSync(inboxDir, { recursive: true });

    busboy.on('file', (name, file, info) => {
      const { filename } = info;
      if (!filename) {
        file.resume();
        return;
      }
      const cleanName = path.basename(filename).replace(/[^a-zA-Z0-9._-]/g, '_');
      const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14);
      const destName = `${stamp}-${cleanName}`;
      const destPath = path.join(inboxDir, destName);

      const p = new Promise((resolve, reject) => {
        const writeStream = fs.createWriteStream(destPath);
        file.pipe(writeStream);

        writeStream.on('finish', () => {
          const relativePath = isProject
            ? `.devbox-inbox/${destName}`
            : destPath;

          uploadedFile = {
            filename: destName,
            path: relativePath,
            fullPath: destPath
          };

          // Type the path into the active tmux pane
          try {
            execSync(`tmux send-keys -t "${session}" -l "${relativePath} "`);
          } catch (e) {
            console.error(`[upload] failed to send-keys to ${session}:`, e.message);
          }
          resolve();
        });

        writeStream.on('error', reject);
      });

      filePromises.push(p);
    });

    busboy.on('finish', async () => {
      try {
        await Promise.all(filePromises);
      } catch (err) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: err.message }));
        return;
      }

      if (!uploadedFile) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'No file received' }));
        return;
      }
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, file: uploadedFile }));
    });

    req.pipe(busboy);
    return;
  }

  // 2. Actions API (zoom, next-window, etc.)
  if (req.method === 'POST' && pathname === '/api/action') {
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      try {
        const data = JSON.parse(body || '{}');
        const session = data.session || 'main-web';
        ensureTmuxSession(session);

        if (data.action === 'zoom') {
          execSync(`tmux resize-pane -Z -t "${session}" 2>/dev/null || true`);
        } else if (data.action === 'next-window') {
          execSync(`tmux next-window -t "${session}" 2>/dev/null || true`);
        } else if (data.action === 'prev-window') {
          execSync(`tmux previous-window -t "${session}" 2>/dev/null || true`);
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

  // 3. Status API
  if (req.method === 'GET' && pathname === '/api/status') {
    const session = url.searchParams.get('session') || 'main-web';
    let cwd = '';
    try {
      cwd = getPaneCwd(session);
    } catch {}
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, session, cwd, node: process.version }));
    return;
  }

  // 4. Static files (public/ and vendor packages)
  let targetPath;
  if (pathname === '/' || pathname === '/index.html') {
    targetPath = path.join(PUBLIC_DIR, 'index.html');
  } else if (pathname.startsWith('/vendor/xterm/')) {
    targetPath = path.join(NODE_MODULES, 'xterm', pathname.replace('/vendor/xterm/', ''));
  } else if (pathname.startsWith('/vendor/addon-fit/')) {
    targetPath = path.join(NODE_MODULES, '@xterm', 'addon-fit', pathname.replace('/vendor/addon-fit/', ''));
  } else if (pathname.startsWith('/vendor/addon-webgl/')) {
    targetPath = path.join(NODE_MODULES, '@xterm', 'addon-webgl', pathname.replace('/vendor/addon-webgl/', ''));
  } else {
    targetPath = path.join(PUBLIC_DIR, pathname);
  }

  if (fs.existsSync(targetPath) && fs.statSync(targetPath).isFile()) {
    res.writeHead(200, { 'Content-Type': getMimeType(targetPath) });
    fs.createReadStream(targetPath).pipe(res);
  } else {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not found');
  }
});

// WebSocket Server for Terminal stream
const wss = new WebSocketServer({ server });

wss.on('connection', (ws, req) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const clientType = url.searchParams.get('client') || 'desktop';
  const cols = parseInt(url.searchParams.get('cols') || '120', 10);
  const rows = parseInt(url.searchParams.get('rows') || '30', 10);

  // Grouped session topology: mobile vs desktop
  const sessionName = clientType === 'mobile' ? 'main-mobile' : 'main-web';
  ensureTmuxSession(sessionName);

  console.log(`[ws] client connected (${clientType}) -> session "${sessionName}" [${cols}x${rows}]`);

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

  term.onData(data => {
    if (ws.readyState === ws.OPEN) {
      ws.send(data);
    }
  });

  ws.on('message', message => {
    const str = message.toString();
    if (str.startsWith('{')) {
      try {
        const parsed = JSON.parse(str);
        if (parsed.type === 'resize' && parsed.cols && parsed.rows) {
          const c = Math.max(parseInt(parsed.cols, 10) || 20, 10);
          const r = Math.max(parseInt(parsed.rows, 10) || 10, 5);
          term.resize(c, r);
          return;
        }
      } catch {}
    }

    term.write(str);
  });

  ws.on('close', () => {
    console.log(`[ws] client disconnected from session "${sessionName}"`);
    term.kill();
  });

  term.onExit(() => {
    ws.close();
  });
});

server.listen(PORT, HOST, () => {
  console.log(`[devbox-web] server listening at http://${HOST}:${PORT}`);
});
