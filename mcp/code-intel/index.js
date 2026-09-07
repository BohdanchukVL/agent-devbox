#!/usr/bin/env node
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

// Standard ignore arguments for ripgrep and ctags
const EXCLUDE_DIRS = [
  'node_modules',
  '.git',
  'target',
  'dist',
  'build',
  'vendor',
  '.venv',
  'venv',
  '__pycache__',
  '.next',
  '.cache',
  'coverage'
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

    const snippet = lines.slice(start, end).map((line, idx) => {
      const lineNum = start + idx + 1;
      const marker = lineNum === targetLine ? '>' : ' ';
      return `${marker} ${String(lineNum).padStart(4, ' ')} │ ${line}`;
    }).join('\n');

    return snippet;
  } catch {
    return null;
  }
}

// 1. Tool: get_outline
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

    // Sort by line number
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

// 2. Tool: find_definition
function handleFindDefinition(args) {
  const symbol = (args.symbol || '').trim();
  if (!symbol) return { error: 'Symbol parameter is required' };

  const searchDir = resolvePath(args.path);
  const exact = args.exact !== false;

  // Language definition regex patterns for fast ripgrep lookup:
  // Rust: fn, struct, enum, trait, type, impl
  // TS/JS: function, class, interface, type, const, let, var, enum
  // Python: def, class
  // Go: func, type
  const wordBoundary = exact ? `\\b${symbol}\\b` : symbol;
  const regexPattern = `^\\s*(export\\s+)?(default\\s+)?(pub\\s+)?(async\\s+)?(function|class|interface|struct|enum|trait|type|fn|def|func|const|let|var)\\s+(\\(.*\\)\\s+)?${wordBoundary}`;

  const rgArgs = [
    '-n',
    '--no-heading',
    '--color=never',
    '--max-count=10',
    '-e', regexPattern,
    searchDir
  ];

  for (const dir of EXCLUDE_DIRS) {
    rgArgs.push('--glob', `!${dir}/**`);
  }

  try {
    const result = spawnSync('rg', rgArgs, {
      encoding: 'utf8',
      timeout: 10000
    });

    const lines = (result.stdout || '').split('\n').filter(Boolean);
    const matches = [];

    for (const line of lines.slice(0, 5)) {
      // Format: /path/to/file.rs:42:pub fn my_func() {
      const parts = line.split(':');
      if (parts.length >= 3) {
        const filePath = parts[0];
        const lineNum = parseInt(parts[1], 10);
        if (!isNaN(lineNum)) {
          const relPath = path.relative(searchDir, filePath) || path.basename(filePath);
          const snippet = getFileSnippet(filePath, lineNum, 2, 12);
          matches.push({
            file: relPath,
            line: lineNum,
            snippet
          });
        }
      }
    }

    // Fallback: If regex didn't match (e.g. macro or ctags-indexed tag), query ctags
    if (matches.length === 0) {
      try {
        const ctagsArgs = [
          '--output-format=json',
          '--fields=+n+K',
          '-R',
          '-f', '-'
        ];
        for (const dir of EXCLUDE_DIRS) {
          ctagsArgs.push(`--exclude=${dir}`);
        }
        ctagsArgs.push(searchDir);

        const ctagsRes = spawnSync('ctags', ctagsArgs, {
          encoding: 'utf8',
          timeout: 8000
        });

        const tagLines = (ctagsRes.stdout || '').split('\n').filter(Boolean);
        for (const tl of tagLines) {
          try {
            const item = JSON.parse(tl);
            const matchesQuery = exact ? item.name === symbol : item.name.toLowerCase().includes(symbol.toLowerCase());
            if (matchesQuery && item.path && item.line) {
              const relPath = path.relative(searchDir, item.path) || path.basename(item.path);
              const snippet = getFileSnippet(item.path, item.line, 2, 12);
              matches.push({
                file: relPath,
                line: item.line,
                snippet
              });
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
      if (m.snippet) {
        output += `\`\`\`\n${m.snippet}\n\`\`\`\n\n`;
      }
    }

    return { text: output.trim() };
  } catch (err) {
    return { error: `Error searching definition: ${err.message}` };
  }
}

// 3. Tool: find_references
function handleFindReferences(args) {
  const symbol = (args.symbol || '').trim();
  if (!symbol) return { error: 'Symbol parameter is required' };

  const searchDir = resolvePath(args.path);
  const limit = Math.min(parseInt(args.limit || '25', 10), 100);

  const rgArgs = [
    '-n',
    '-w',
    '--no-heading',
    '--color=never',
    '--max-columns=200',
    '-F', symbol,
    searchDir
  ];

  for (const dir of EXCLUDE_DIRS) {
    rgArgs.push('--glob', `!${dir}/**`);
  }

  if (args.glob) {
    rgArgs.push('--glob', args.glob);
  }

  try {
    const result = spawnSync('rg', rgArgs, {
      encoding: 'utf8',
      timeout: 10000
    });

    const lines = (result.stdout || '').split('\n').filter(Boolean);
    if (lines.length === 0) {
      return { text: `No references found for "${symbol}" in ${searchDir}` };
    }

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
    if (totalCount > limit) {
      header += ` (showing first ${limit})`;
    }

    return {
      text: `${header}:\n\`\`\`text\n${formatted}\n\`\`\``
    };
  } catch (err) {
    return { error: `Error searching references: ${err.message}` };
  }
}

// 4. Tool: find_files
function handleFindFiles(args) {
  const query = (args.query || '').trim();
  const searchDir = resolvePath(args.path);
  const limit = Math.min(parseInt(args.limit || '30', 10), 100);

  const rgArgs = ['--files', searchDir];
  for (const dir of EXCLUDE_DIRS) {
    rgArgs.push('--glob', `!${dir}/**`);
  }
  if (query) {
    rgArgs.push('--glob', `*${query}*`);
  }

  try {
    const result = spawnSync('rg', rgArgs, {
      encoding: 'utf8',
      timeout: 5000
    });

    const files = (result.stdout || '').split('\n').filter(Boolean);
    if (files.length === 0) {
      return { text: `No files matching "${query}" in ${searchDir}` };
    }

    const relativeFiles = files.slice(0, limit).map(f => path.relative(searchDir, f) || f);
    return {
      text: `Found ${files.length} file(s):\n\`\`\`text\n${relativeFiles.join('\n')}\n\`\`\``
    };
  } catch (err) {
    return { error: `Error finding files: ${err.message}` };
  }
}

// Server setup
const server = new Server(
  {
    name: 'devbox-code-intel',
    version: '0.1.0',
  },
  {
    capabilities: {
      tools: {},
    },
  }
);

server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: [
      {
        name: 'get_outline',
        description: 'HIGH PRIORITY: Extract high-level symbol outline (functions, classes, methods, structs, traits, interfaces) with line numbers from a file without reading the whole file. Use this to inspect file structure and save 90%+ tokens.',
        inputSchema: {
          type: 'object',
          properties: {
            path: {
              type: 'string',
              description: 'Relative or absolute path to the file'
            }
          },
          required: ['path']
        }
      },
      {
        name: 'find_definition',
        description: 'HIGH PRIORITY: Find where a function, struct, class, method, or trait is defined in the workspace. Returns the exact file, line, and a 12-line preview snippet of the definition so you do NOT need to read the full file.',
        inputSchema: {
          type: 'object',
          properties: {
            symbol: {
              type: 'string',
              description: 'Exact or partial symbol name (e.g. UserSession, handle_request, calculateTax)'
            },
            path: {
              type: 'string',
              description: 'Optional directory or project root to search in. Defaults to current directory.'
            },
            exact: {
              type: 'boolean',
              description: 'Whether to require exact symbol name match. Defaults to true.'
            }
          },
          required: ['symbol']
        }
      },
      {
        name: 'find_references',
        description: 'Find all usages, call-sites, and references to a symbol across the workspace using fast ripgrep. Automatically ignores build artifacts (target/, node_modules/, vendor/, etc.).',
        inputSchema: {
          type: 'object',
          properties: {
            symbol: {
              type: 'string',
              description: 'Exact symbol name to find references for'
            },
            path: {
              type: 'string',
              description: 'Optional directory to search in. Defaults to current directory.'
            },
            glob: {
              type: 'string',
              description: 'Optional file glob filter, e.g. "*.rs" or "*.ts"'
            },
            limit: {
              type: 'number',
              description: 'Max number of results to return (default: 25)'
            }
          },
          required: ['symbol']
        }
      },
      {
        name: 'find_files',
        description: 'Find files in workspace matching a pattern or query, respecting .gitignore and excluding build artifacts.',
        inputSchema: {
          type: 'object',
          properties: {
            query: {
              type: 'string',
              description: 'File name pattern or glob to search (e.g. "config", "*.rs", "server")'
            },
            path: {
              type: 'string',
              description: 'Optional directory to search in. Defaults to current directory.'
            },
            limit: {
              type: 'number',
              description: 'Max number of files to return (default: 30)'
            }
          },
          required: ['query']
        }
      }
    ]
  };
});

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args = {} } = request.params;

  let result;
  if (name === 'get_outline') {
    result = handleGetOutline(args);
  } else if (name === 'find_definition') {
    result = handleFindDefinition(args);
  } else if (name === 'find_references') {
    result = handleFindReferences(args);
  } else if (name === 'find_files') {
    result = handleFindFiles(args);
  } else {
    return {
      content: [{ type: 'text', text: `Unknown tool: ${name}` }],
      isError: true,
    };
  }

  if (result.error) {
    return {
      content: [{ type: 'text', text: `Error: ${result.error}` }],
      isError: true,
    };
  }

  return {
    content: [{ type: 'text', text: result.text || 'Success' }]
  };
});

const transport = new StdioServerTransport();
await server.connect(transport);
