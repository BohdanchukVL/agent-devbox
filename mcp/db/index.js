#!/usr/bin/env node
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import sqlite from 'node:sqlite';
import pg from 'pg';
import fs from 'node:fs';
import path from 'node:path';

const { Client: PgClient } = pg;

// Helper: Escape double quotes in SQLite identifiers
function escapeSqliteIdent(identifier) {
  return String(identifier).replace(/"/g, '""');
}

// Helper: Discover active database if none provided
function resolveConnection(inputTarget) {
  if (inputTarget && typeof inputTarget === 'string' && inputTarget.trim()) {
    const target = inputTarget.trim();
    if (isPostgres(target)) {
      try {
        const u = new URL(target);
        if (u.protocol !== 'postgres:' && u.protocol !== 'postgresql:') {
          return null;
        }
      } catch {
        return null;
      }
    }
    return target;
  }

  // 1. Environment variable (unless disabled via DEVBOX_DB_DISABLE_ENV)
  if (process.env.DEVBOX_DB_DISABLE_ENV !== 'true' && process.env.DATABASE_URL) {
    return process.env.DATABASE_URL;
  }

  // 2. Check .env in cwd (unless disabled via DEVBOX_DB_DISABLE_ENV)
  if (process.env.DEVBOX_DB_DISABLE_ENV !== 'true') {
    const envPath = path.join(process.cwd(), '.env');
    if (fs.existsSync(envPath)) {
      try {
        const content = fs.readFileSync(envPath, 'utf8');
        const match = content.match(/^DATABASE_URL\s*=\s*["']?([^"'\r\n]+)["']?/m);
        if (match && match[1]) return match[1].trim();
      } catch {}
    }
  }

  // 3. Search for SQLite files in cwd or ./data
  const candidates = [
    'dev.db', 'dev.sqlite', 'dev.sqlite3',
    'app.db', 'app.sqlite', 'app.sqlite3',
    'database.sqlite', 'database.db',
    'data/dev.db', 'data/app.db', 'data.db'
  ];

  for (const c of candidates) {
    const full = path.resolve(process.cwd(), c);
    if (fs.existsSync(full)) return full;
  }

  // General glob for any .db / .sqlite in current directory (non-recursive)
  try {
    const files = fs.readdirSync(process.cwd());
    const dbFile = files.find(f => f.endsWith('.sqlite') || f.endsWith('.sqlite3') || (f.endsWith('.db') && !f.includes('summary')));
    if (dbFile) return path.resolve(process.cwd(), dbFile);
  } catch {}

  return null;
}

function isPostgres(target) {
  return target && (target.startsWith('postgres://') || target.startsWith('postgresql://'));
}

function formatMarkdownTable(headers, rows) {
  if (!rows || rows.length === 0) return '_No rows returned._';

  const cols = headers.map(h => String(h));
  let md = '| ' + cols.join(' | ') + ' |\n';
  md += '| ' + cols.map(() => '---').join(' | ') + ' |\n';

  for (const r of rows) {
    const vals = cols.map(c => {
      const val = r[c];
      if (val === null || val === undefined) return '`NULL`';
      if (typeof val === 'object') return JSON.stringify(val);
      return String(val).replace(/\|/g, '\\|').replace(/\n/g, ' ');
    });
    md += '| ' + vals.join(' | ') + ' |\n';
  }
  return md;
}

// 1. Tool: db_list_tables
async function handleListTables(args) {
  const target = resolveConnection(args.connection);
  if (!target) {
    return { error: 'No database specified and none detected in current workspace (provide a path to a .db file or a postgres:// connection URL).' };
  }

  if (isPostgres(target)) {
    const client = new PgClient({ connectionString: target });
    try {
      await client.connect();
      const res = await client.query(`
        SELECT table_name, table_type
        FROM information_schema.tables
        WHERE table_schema = 'public'
        ORDER BY table_name;
      `);
      await client.end();

      if (res.rows.length === 0) {
        return { text: `Connected to PostgreSQL, but no tables found in 'public' schema.` };
      }

      let out = `### PostgreSQL Tables (${res.rows.length} total)\n`;
      for (const r of res.rows) {
        out += `- \`${r.table_name}\` (${r.table_type.toLowerCase()})\n`;
      }
      return { text: out };
    } catch (err) {
      try { await client.end(); } catch {}
      return { error: `PostgreSQL connection error: ${err.message}` };
    }
  } else {
    // SQLite
    const dbPath = path.resolve(process.cwd(), target);
    if (!fs.existsSync(dbPath)) {
      return { error: `SQLite file not found: ${dbPath}` };
    }

    try {
      const db = new sqlite.DatabaseSync(dbPath, { readOnly: true });
      const rows = db.prepare(`
        SELECT name, type
        FROM sqlite_master
        WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%'
        ORDER BY name;
      `).all();

      if (rows.length === 0) {
        return { text: `Connected to SQLite (${path.basename(dbPath)}), but no tables found.` };
      }

      let out = `### SQLite Tables (\`${path.basename(dbPath)}\` - ${rows.length} total)\n`;
      for (const r of rows) {
        let count = 0;
        if (r.type === 'table') {
          try {
            const countRow = db.prepare(`SELECT count(*) as count FROM "${escapeSqliteIdent(r.name)}"`).get();
            count = countRow?.count ?? 0;
          } catch {}
        }
        out += `- \`${r.name}\` (${r.type}${r.type === 'table' ? `, ${count.toLocaleString()} rows` : ''})\n`;
      }
      db.close();
      return { text: out };
    } catch (err) {
      return { error: `SQLite error: ${err.message}` };
    }
  }
}

// 2. Tool: db_describe_table
async function handleDescribeTable(args) {
  const table = (args.table || '').trim();
  if (!table) return { error: 'Table parameter is required' };

  const target = resolveConnection(args.connection);
  if (!target) return { error: 'No database connection or file found' };

  if (isPostgres(target)) {
    const client = new PgClient({ connectionString: target });
    try {
      await client.connect();
      const colRes = await client.query(`
        SELECT column_name, data_type, is_nullable, column_default
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1
        ORDER BY ordinal_position;
      `, [table]);

      if (colRes.rows.length === 0) {
        await client.end();
        return { text: `Table \`${table}\` not found in PostgreSQL.` };
      }

      const pkRes = await client.query(`
        SELECT c.column_name
        FROM information_schema.table_constraints tc
        JOIN information_schema.constraint_column_usage AS ccu USING (constraint_schema, constraint_name)
        JOIN information_schema.columns AS c ON c.table_schema = tc.constraint_schema
          AND tc.table_name = c.table_name AND ccu.column_name = c.column_name
        WHERE constraint_type = 'PRIMARY KEY' AND tc.table_name = $1;
      `, [table]);

      await client.end();

      const pks = new Set(pkRes.rows.map(r => r.column_name));
      const cols = colRes.rows.map(r => ({
        Column: r.column_name,
        Type: r.data_type,
        Nullable: r.is_nullable,
        Default: r.column_default || '-',
        Key: pks.has(r.column_name) ? 'PRIMARY KEY' : ''
      }));

      const tableMd = formatMarkdownTable(['Column', 'Type', 'Nullable', 'Default', 'Key'], cols);
      return { text: `### Table \`${table}\` (PostgreSQL)\n\n${tableMd}` };
    } catch (err) {
      try { await client.end(); } catch {}
      return { error: `PostgreSQL error: ${err.message}` };
    }
  } else {
    // SQLite
    const dbPath = path.resolve(process.cwd(), target);
    if (!fs.existsSync(dbPath)) return { error: `SQLite file not found: ${dbPath}` };

    try {
      const db = new sqlite.DatabaseSync(dbPath, { readOnly: true });
      const safeTable = escapeSqliteIdent(table);
      const colRows = db.prepare(`PRAGMA table_info("${safeTable}")`).all();

      if (colRows.length === 0) {
        db.close();
        return { text: `Table \`${table}\` not found in SQLite.` };
      }

      const fks = db.prepare(`PRAGMA foreign_key_list("${safeTable}")`).all();
      const idxs = db.prepare(`PRAGMA index_list("${safeTable}")`).all();
      db.close();

      const cols = colRows.map(r => ({
        Column: r.name,
        Type: r.type || 'ANY',
        Nullable: r.notnull === 1 ? 'NO' : 'YES',
        Default: r.dflt_value !== null ? r.dflt_value : '-',
        Key: r.pk === 1 ? 'PRIMARY KEY' : ''
      }));

      let out = `### Table \`${table}\` (SQLite: \`${path.basename(dbPath)}\`)\n\n`;
      out += formatMarkdownTable(['Column', 'Type', 'Nullable', 'Default', 'Key'], cols);

      if (fks.length > 0) {
        out += '\n\n**Foreign Keys:**\n';
        for (const fk of fks) {
          out += `- \`${fk.from}\` -> \`${fk.table}(${fk.to})\`\n`;
        }
      }

      if (idxs.length > 0) {
        out += '\n\n**Indexes:**\n';
        for (const idx of idxs) {
          out += `- \`${idx.name}\` (${idx.unique === 1 ? 'UNIQUE' : 'INDEX'})\n`;
        }
      }

      return { text: out };
    } catch (err) {
      return { error: `SQLite error: ${err.message}` };
    }
  }
}

// 3. Tool: db_query (Safe Read-Only)
async function handleQuery(args) {
  let query = (args.query || '').trim();
  if (!query) return { error: 'Query parameter is required' };

  // Safety filter: Read-only enforcement
  const cleaned = query.replace(/^(\s*--[^\n]*\n|\s*\/\*[\s\S]*?\*\/)*/g, '').trim().toUpperCase();
  if (!cleaned.startsWith('SELECT') && !cleaned.startsWith('WITH') && !cleaned.startsWith('EXPLAIN') && !cleaned.startsWith('PRAGMA')) {
    return { error: 'Security restriction: Only read-only queries (SELECT, WITH, EXPLAIN, PRAGMA) are permitted via MCP.' };
  }

  // Prevent multiple statements
  if (query.split(';').map(s => s.trim()).filter(Boolean).length > 1) {
    return { error: 'Security restriction: Multiple SQL statements are not permitted.' };
  }

  // Disallow administrative, file I/O, sleep, and dblink functions
  const dangerousPatterns = /\b(pg_sleep|pg_read_file|pg_read_binary_file|pg_write_file|pg_ls_dir|dblink|dblink_exec|lo_import|lo_export|query_to_xml)\b/i;
  if (dangerousPatterns.test(query)) {
    return { error: 'Security restriction: Calling administrative, file I/O, network, or sleep functions is not permitted.' };
  }

  const limit = Math.min(parseInt(args.limit || '25', 10), 100);
  const target = resolveConnection(args.connection);
  if (!target) return { error: 'No database connection or file found' };

  // Inject limit if not already present
  if (!query.toUpperCase().includes('LIMIT') && !cleaned.startsWith('EXPLAIN') && !cleaned.startsWith('PRAGMA')) {
    query = `${query.replace(/;?\s*$/, '')} LIMIT ${limit};`;
  }

  if (isPostgres(target)) {
    const client = new PgClient({ connectionString: target });
    try {
      await client.connect();
      await client.query("SET statement_timeout = '5s'");
      // Read-only transaction enforcement
      await client.query('BEGIN READ ONLY');
      const res = await client.query(query);
      await client.query('ROLLBACK');
      await client.end();

      if (res.rows.length === 0) {
        return { text: `Query executed successfully. 0 rows returned.` };
      }

      const headers = Object.keys(res.rows[0]);
      const tableMd = formatMarkdownTable(headers, res.rows);
      return { text: `### Query Result (${res.rows.length} rows)\n\n${tableMd}` };
    } catch (err) {
      try { await client.query('ROLLBACK'); await client.end(); } catch {}
      return { error: `PostgreSQL query error: ${err.message}` };
    }
  } else {
    // SQLite
    const dbPath = path.resolve(process.cwd(), target);
    if (!fs.existsSync(dbPath)) return { error: `SQLite file not found: ${dbPath}` };

    try {
      const db = new sqlite.DatabaseSync(dbPath, { readOnly: true });
      const rows = db.prepare(query).all();
      db.close();

      if (rows.length === 0) {
        return { text: `Query executed successfully. 0 rows returned.` };
      }

      const headers = Object.keys(rows[0]);
      const tableMd = formatMarkdownTable(headers, rows);
      return { text: `### Query Result (${rows.length} rows)\n\n${tableMd}` };
    } catch (err) {
      return { error: `SQLite query error: ${err.message}` };
    }
  }
}

// 4. Tool: db_schema_dump
async function handleSchemaDump(args) {
  const target = resolveConnection(args.connection);
  if (!target) return { error: 'No database connection or file found' };

  if (isPostgres(target)) {
    const listRes = await handleListTables(args);
    if (listRes.error) return listRes;
    return { text: listRes.text };
  } else {
    // SQLite: export CREATE TABLE statements
    const dbPath = path.resolve(process.cwd(), target);
    if (!fs.existsSync(dbPath)) return { error: `SQLite file not found: ${dbPath}` };

    try {
      const db = new sqlite.DatabaseSync(dbPath, { readOnly: true });
      const rows = db.prepare(`
        SELECT sql
        FROM sqlite_master
        WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' AND sql IS NOT NULL
        ORDER BY name;
      `).all();
      db.close();

      if (rows.length === 0) return { text: `No schema found in SQLite database.` };

      const sqlDump = rows.map(r => r.sql + ';').join('\n\n');
      return {
        text: `### SQLite Database Schema (\`${path.basename(dbPath)}\`)\n\`\`\`sql\n${sqlDump}\n\`\`\``
      };
    } catch (err) {
      return { error: `SQLite error: ${err.message}` };
    }
  }
}

const server = new Server(
  { name: 'devbox-db', version: '0.1.0' },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'db_list_tables',
      description: 'List all tables, views, and row counts in the active SQLite or PostgreSQL database. Automatically detects database file or DATABASE_URL if not provided.',
      inputSchema: {
        type: 'object',
        properties: {
          connection: { type: 'string', description: 'Optional path to .db/.sqlite file or postgres:// connection URL' }
        }
      }
    },
    {
      name: 'db_describe_table',
      description: 'Describe the schema of a specific table (columns, data types, nullable, primary keys, foreign keys, and indexes). Essential before writing queries or models.',
      inputSchema: {
        type: 'object',
        properties: {
          table: { type: 'string', description: 'Name of the table to describe' },
          connection: { type: 'string', description: 'Optional db path or URL' }
        },
        required: ['table']
      }
    },
    {
      name: 'db_query',
      description: 'Execute a safe, read-only SQL query (SELECT, EXPLAIN, WITH) with automatic LIMIT protection. Never modifies data.',
      inputSchema: {
        type: 'object',
        properties: {
          query: { type: 'string', description: 'SQL SELECT query to execute' },
          limit: { type: 'number', description: 'Maximum rows to return (default 25)' },
          connection: { type: 'string', description: 'Optional db path or URL' }
        },
        required: ['query']
      }
    },
    {
      name: 'db_schema_dump',
      description: 'Get a full DDL schema dump of the database to understand all tables and relationships at once.',
      inputSchema: {
        type: 'object',
        properties: {
          connection: { type: 'string', description: 'Optional db path or URL' }
        }
      }
    }
  ]
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args = {} } = request.params;
  let result;
  if (name === 'db_list_tables') result = await handleListTables(args);
  else if (name === 'db_describe_table') result = await handleDescribeTable(args);
  else if (name === 'db_query') result = await handleQuery(args);
  else if (name === 'db_schema_dump') result = await handleSchemaDump(args);
  else return { content: [{ type: 'text', text: `Unknown tool: ${name}` }], isError: true };

  if (result.error) return { content: [{ type: 'text', text: `Error: ${result.error}` }], isError: true };
  return { content: [{ type: 'text', text: result.text || 'Success' }] };
});

const transport = new StdioServerTransport();
await server.connect(transport);
