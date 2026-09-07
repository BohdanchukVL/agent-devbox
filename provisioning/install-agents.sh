#!/usr/bin/env bash
# AI coding agents, installed into a USER-OWNED npm prefix so the dev user can
# self-update them — root-owned globals break `claude`/`codex` auto-update
# ("no write permission to npm prefix"). Runs once as root via cloud-init after
# install-base.sh; flags come from /etc/devbox/devbox.env. Idempotent.
set -euo pipefail
trap 'touch /etc/devbox/.failed 2>/dev/null || true' ERR

. /etc/devbox/devbox.env
U="$DEVBOX_USER"
H="/home/$U"
PREFIX="$H/.npm-global"

log() { echo "[devbox $(date -u +%H:%M:%S)] $*"; }

# per-user global prefix owned by dev → agents write their own updates
install -d -o "$U" -g "$U" "$PREFIX"
sudo -u "$U" -H npm config set prefix "$PREFIX"
# put the prefix on PATH for login bash/zsh + tmux panes
echo 'export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"' > /etc/profile.d/devbox-npm.sh
chmod 0644 /etc/profile.d/devbox-npm.sh
# put the prefix on PATH for non-interactive zsh sessions (e.g. ssh dev@host claude ...)
install -m 0644 -o "$U" -g "$U" /dev/null "$H/.zshenv"
echo 'export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"' >> "$H/.zshenv"

# install as dev so files land in the dev-owned prefix (npm reads ~/.npmrc)
agent() { sudo -u "$U" -H npm install -g "$1"; }

if [ "$INSTALL_CODEX" = "true" ]; then
  log "installing Codex CLI"
  which bwrap >/dev/null 2>&1 || apt-get install -y --no-install-recommends bubblewrap || true
  agent @openai/codex
fi

if [ "$INSTALL_CLAUDE" = "true" ]; then
  log "installing Claude Code"
  agent @anthropic-ai/claude-code
fi

if [ "$INSTALL_OPENCODE" = "true" ]; then
  log "installing OpenCode"
  agent opencode-ai
fi

if [ "${INSTALL_ANTIGRAVITY:-false}" = "true" ]; then
  log "installing Antigravity CLI (agy)"
  install -d -o "$U" -g "$U" "$H/.local/bin"
  # standalone Go binary → ~/.local/bin/agy (not npm); tolerate a failed fetch
  sudo -u "$U" -H bash -c 'export PATH="$HOME/.local/bin:$PATH"; curl -fsSL https://antigravity.google/cli/install.sh | bash' \
    || log "antigravity install failed (skipping)"
  [ -f "$H/.local/bin/agy" ] && ln -sf "$H/.local/bin/agy" /usr/local/bin/agy || true
fi

log "installing code intelligence and MCP tools"
agent @ast-grep/cli
agent @notprolands/ast-grep-mcp

# Setup devbox-code-intel MCP server
install -d -o "$U" -g "$U" "$H/.devbox/mcp/code-intel"
if [ -d "/opt/devbox/mcp/code-intel" ]; then
  cp -r /opt/devbox/mcp/code-intel/* "$H/.devbox/mcp/code-intel/"
else
  cat > "$H/.devbox/mcp/code-intel/package.json" <<'EOF'
{
  "name": "devbox-code-intel",
  "version": "0.1.0",
  "type": "module",
  "main": "index.js",
  "dependencies": {
    "@modelcontextprotocol/sdk": "^1.30.0"
  }
}
EOF

  cat > "$H/.devbox/mcp/code-intel/index.js" <<'EOF'
#!/usr/bin/env node
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const EXCLUDE_DIRS = [
  'node_modules', '.git', 'target', 'dist', 'build', 'vendor',
  '.venv', 'venv', '__pycache__', '.next', '.cache', 'coverage'
];

function resolvePath(targetPath) {
  if (!targetPath) return process.cwd();
  if (path.isAbsolute(targetPath)) return targetPath;
  return path.resolve(process.cwd(), targetPath);
}

function getFileSnippet(filePath, targetLine, contextBefore = 2, contextAfter = 10) {
  try {
    if (!fs.existsSync(filePath)) return null;
    const content = fs.readFileSync(filePath, 'utf8');
    const lines = content.split('\n');
    const totalLines = lines.length;

    const start = Math.max(0, targetLine - 1 - contextBefore);
    const end = Math.min(totalLines, targetLine - 1 + contextAfter + 1);

    return lines.slice(start, end).map((line, idx) => {
      const lineNum = start + idx + 1;
      const marker = lineNum === targetLine ? '>' : ' ';
      return `${marker} ${String(lineNum).padStart(4, ' ')} │ ${line}`;
    }).join('\n');
  } catch {
    return null;
  }
}

function handleGetOutline(args) {
  const filePath = resolvePath(args.path);
  if (!fs.existsSync(filePath)) {
    return { error: `File not found: ${args.path}` };
  }

  try {
    const result = spawnSync('ctags', ['--output-format=json', '--fields=+n+K+S', '-f', '-', filePath], {
      encoding: 'utf8',
      timeout: 5000
    });

    if (result.error) {
      return { error: `Failed to execute ctags: ${result.error.message}` };
    }

    const lines = (result.stdout || '').split('\n').filter(Boolean);
    const symbols = [];

    for (const line of lines) {
      try {
        const item = JSON.parse(line);
        if (item._type === 'tag' && item.name) {
          symbols.push({
            name: item.name,
            kind: item.kind || 'unknown',
            line: item.line,
            scope: item.scope ? `${item.scopeKind ? item.scopeKind + ' ' : ''}${item.scope}` : null
          });
        }
      } catch {}
    }

    if (symbols.length === 0) {
      return { text: `No structured symbols found in ${path.basename(filePath)}` };
    }

    symbols.sort((a, b) => a.line - b.line);

    const formatted = symbols.map(s => {
      const scopePart = s.scope ? ` (${s.scope})` : '';
      return `L${String(s.line).padEnd(5, ' ')} [${s.kind}] ${s.name}${scopePart}`;
    }).join('\n');

    return {
      text: `### Outline for \`${path.basename(filePath)}\` (${symbols.length} symbols)\n\`\`\`text\n${formatted}\n\`\`\``
    };
  } catch (err) {
    return { error: `Error generating outline: ${err.message}` };
  }
}

function handleFindDefinition(args) {
  const symbol = (args.symbol || '').trim();
  if (!symbol) return { error: 'Symbol parameter is required' };

  const searchDir = resolvePath(args.path);
  const exact = args.exact !== false;

  const wordBoundary = exact ? `\\b${symbol}\\b` : symbol;
  const regexPattern = `^\\s*(export\\s+)?(default\\s+)?(pub\\s+)?(async\\s+)?(function|class|interface|struct|enum|trait|type|fn|def|func|const|let|var)\\s+(\\(.*\\)\\s+)?${wordBoundary}`;

  const rgArgs = [
    '-n', '--no-heading', '--color=never', '--max-count=10',
    '-e', regexPattern, searchDir
  ];

  for (const dir of EXCLUDE_DIRS) {
    rgArgs.push('--glob', `!${dir}/**`);
  }

  try {
    const result = spawnSync('rg', rgArgs, { encoding: 'utf8', timeout: 10000 });
    const lines = (result.stdout || '').split('\n').filter(Boolean);
    const matches = [];

    for (const line of lines.slice(0, 5)) {
      const parts = line.split(':');
      if (parts.length >= 3) {
        const filePath = parts[0];
        const lineNum = parseInt(parts[1], 10);
        if (!isNaN(lineNum)) {
          const relPath = path.relative(searchDir, filePath) || path.basename(filePath);
          const snippet = getFileSnippet(filePath, lineNum, 2, 12);
          matches.push({ file: relPath, line: lineNum, snippet });
        }
      }
    }

    if (matches.length === 0) {
      try {
        const ctagsArgs = ['--output-format=json', '--fields=+n+K', '-R', '-f', '-'];
        for (const dir of EXCLUDE_DIRS) ctagsArgs.push(`--exclude=${dir}`);
        ctagsArgs.push(searchDir);

        const ctagsRes = spawnSync('ctags', ctagsArgs, { encoding: 'utf8', timeout: 8000 });
        const tagLines = (ctagsRes.stdout || '').split('\n').filter(Boolean);
        for (const tl of tagLines) {
          try {
            const item = JSON.parse(tl);
            const matchesQuery = exact ? item.name === symbol : item.name.toLowerCase().includes(symbol.toLowerCase());
            if (matchesQuery && item.path && item.line) {
              const relPath = path.relative(searchDir, item.path) || path.basename(item.path);
              const snippet = getFileSnippet(item.path, item.line, 2, 12);
              matches.push({ file: relPath, line: item.line, snippet });
              if (matches.length >= 5) break;
            }
          } catch {}
        }
      } catch {}
    }

    if (matches.length === 0) {
      return { text: `No definition found for symbol "${symbol}" in ${searchDir}` };
    }

    let output = `Found ${matches.length} definition(s) for \`${symbol}\`:\n\n`;
    for (const m of matches) {
      output += `### \`${m.file}:${m.line}\`\n`;
      if (m.snippet) output += `\`\`\`\n${m.snippet}\n\`\`\`\n\n`;
    }
    return { text: output.trim() };
  } catch (err) {
    return { error: `Error searching definition: ${err.message}` };
  }
}

function handleFindReferences(args) {
  const symbol = (args.symbol || '').trim();
  if (!symbol) return { error: 'Symbol parameter is required' };

  const searchDir = resolvePath(args.path);
  const limit = Math.min(parseInt(args.limit || '25', 10), 100);

  const rgArgs = [
    '-n', '-w', '--no-heading', '--color=never',
    '--max-columns=200', '-F', symbol, searchDir
  ];

  for (const dir of EXCLUDE_DIRS) rgArgs.push('--glob', `!${dir}/**`);
  if (args.glob) rgArgs.push('--glob', args.glob);

  try {
    const result = spawnSync('rg', rgArgs, { encoding: 'utf8', timeout: 10000 });
    const lines = (result.stdout || '').split('\n').filter(Boolean);
    if (lines.length === 0) return { text: `No references found for "${symbol}" in ${searchDir}` };

    const totalCount = lines.length;
    const truncated = lines.slice(0, limit);

    const formatted = truncated.map(l => {
      const parts = l.split(':');
      if (parts.length >= 3) {
        const filePath = path.relative(searchDir, parts[0]) || path.basename(parts[0]);
        const lineNum = parts[1];
        const content = parts.slice(2).join(':').trim();
        return `${filePath}:${lineNum}  ${content}`;
      }
      return l;
    }).join('\n');

    let header = `Found ${totalCount} reference(s) for \`${symbol}\``;
    if (totalCount > limit) header += ` (showing first ${limit})`;
    return { text: `${header}:\n\`\`\`text\n${formatted}\n\`\`\`` };
  } catch (err) {
    return { error: `Error searching references: ${err.message}` };
  }
}

function handleFindFiles(args) {
  const query = (args.query || '').trim();
  const searchDir = resolvePath(args.path);
  const limit = Math.min(parseInt(args.limit || '30', 10), 100);

  const rgArgs = ['--files', searchDir];
  for (const dir of EXCLUDE_DIRS) rgArgs.push('--glob', `!${dir}/**`);
  if (query) rgArgs.push('--glob', `*${query}*`);

  try {
    const result = spawnSync('rg', rgArgs, { encoding: 'utf8', timeout: 5000 });
    const files = (result.stdout || '').split('\n').filter(Boolean);
    if (files.length === 0) return { text: `No files matching "${query}" in ${searchDir}` };

    const relativeFiles = files.slice(0, limit).map(f => path.relative(searchDir, f) || f);
    return { text: `Found ${files.length} file(s):\n\`\`\`text\n${relativeFiles.join('\n')}\n\`\`\`` };
  } catch (err) {
    return { error: `Error finding files: ${err.message}` };
  }
}

const server = new Server(
  { name: 'devbox-code-intel', version: '0.1.0' },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'get_outline',
      description: 'HIGH PRIORITY: Extract high-level symbol outline (functions, classes, methods, structs, traits, interfaces) with line numbers from a file without reading the whole file. Use this to inspect file structure and save 90%+ tokens.',
      inputSchema: {
        type: 'object',
        properties: { path: { type: 'string', description: 'Path to file' } },
        required: ['path']
      }
    },
    {
      name: 'find_definition',
      description: 'HIGH PRIORITY: Find where a function, struct, class, method, or trait is defined in the workspace. Returns the exact file, line, and a 12-line preview snippet of the definition so you do NOT need to read the full file.',
      inputSchema: {
        type: 'object',
        properties: {
          symbol: { type: 'string', description: 'Exact or partial symbol name' },
          path: { type: 'string', description: 'Directory to search in' },
          exact: { type: 'boolean', description: 'Whether to require exact symbol name match' }
        },
        required: ['symbol']
      }
    },
    {
      name: 'find_references',
      description: 'Find all usages, call-sites, and references to a symbol across the workspace using fast ripgrep. Automatically ignores build artifacts.',
      inputSchema: {
        type: 'object',
        properties: {
          symbol: { type: 'string', description: 'Exact symbol name' },
          path: { type: 'string', description: 'Directory to search in' },
          glob: { type: 'string', description: 'Optional file glob filter' },
          limit: { type: 'number', description: 'Max number of results' }
        },
        required: ['symbol']
      }
    },
    {
      name: 'find_files',
      description: 'Find files in workspace matching a pattern or query, respecting .gitignore.',
      inputSchema: {
        type: 'object',
        properties: {
          query: { type: 'string', description: 'File pattern or glob' },
          path: { type: 'string', description: 'Directory to search in' },
          limit: { type: 'number', description: 'Max files to return' }
        },
        required: ['query']
      }
    }
  ]
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args = {} } = request.params;
  let result;
  if (name === 'get_outline') result = handleGetOutline(args);
  else if (name === 'find_definition') result = handleFindDefinition(args);
  else if (name === 'find_references') result = handleFindReferences(args);
  else if (name === 'find_files') result = handleFindFiles(args);
  else return { content: [{ type: 'text', text: `Unknown tool: ${name}` }], isError: true };

  if (result.error) return { content: [{ type: 'text', text: `Error: ${result.error}` }], isError: true };
  return { content: [{ type: 'text', text: result.text || 'Success' }] };
});

const transport = new StdioServerTransport();
await server.connect(transport);
EOF
  chmod +x "$H/.devbox/mcp/code-intel/index.js"
fi

chown -R "$U:$U" "$H/.devbox/mcp/code-intel"
sudo -u "$U" -H bash -c "cd '$H/.devbox/mcp/code-intel' && npm install --omit=dev" || true

# Pre-configure MCP servers for Claude Code
if command -v claude >/dev/null 2>&1 || [ -x "$PREFIX/bin/claude" ]; then
  sudo -u "$U" -H bash -c "export PATH=\"$PREFIX/bin:\$PATH\"; claude mcp add -s user ast-grep -- ast-grep-mcp 2>/dev/null || true"
  sudo -u "$U" -H bash -c "export PATH=\"$PREFIX/bin:\$PATH\"; claude mcp add -s user code-intel -- '$H/.devbox/mcp/code-intel/index.js' 2>/dev/null || true"
fi

# Setup token-saving rules for agents
install -d -o "$U" -g "$U" "$H/.claude" "$H/.gemini/config"
if [ -f "/opt/devbox/CLAUDE.md" ]; then
  install -m 0644 -o "$U" -g "$U" /opt/devbox/CLAUDE.md "$H/.claude/CLAUDE.md"
else
  cat > "$H/.claude/CLAUDE.md" <<'EOF'
# Agent Devbox Guidelines: Token & Context Optimization

## Code Navigation & Search Rules
- **DO NOT** read entire files with `cat` or broad file-viewing tools when exploring or searching for code symbols.
- **File Structure**: ALWAYS use `code-intel:get_outline` to inspect classes, functions, methods, traits, structs, and line numbers before opening or editing a file.
- **Symbol Definitions**: ALWAYS use `code-intel:find_definition` to locate function, struct, class, or type definitions. It returns the exact file, line number, and a 12-line preview snippet of the definition.
- **Symbol Usages**: Use `code-intel:find_references` to find call-sites across the codebase. It automatically ignores noisy build directories (`target/`, `node_modules/`, `vendor/`, `.git/`, `.venv/`).
- **AST Pattern Matching**: Use `ast-grep:find_code` or `ast-grep:rewrite_code` for syntax-aware pattern searches and structural refactoring across Rust, TypeScript, JavaScript, Go, and Python.
- **Terminal Execution**: Keep command output concise. Pipe long outputs through `head`, `tail`, or `grep` to prevent context bloating.
EOF
fi

install -m 0644 -o "$U" -g "$U" "$H/.claude/CLAUDE.md" "$H/.gemini/config/AGENTS.md"
[ -d /workspace ] && install -m 0644 -o "$U" -g "$U" "$H/.claude/CLAUDE.md" /workspace/CLAUDE.md 2>/dev/null || true

# Pre-configure MCP for Antigravity
cat > "$H/.gemini/config/mcp_config.json" <<EOF
{
  "mcpServers": {
    "code-intel": {
      "command": "node",
      "args": ["$H/.devbox/mcp/code-intel/index.js"]
    },
    "ast-grep": {
      "command": "ast-grep-mcp",
      "args": []
    }
  }
}
EOF
chown "$U:$U" "$H/.gemini/config/mcp_config.json"

log "agent install done"
