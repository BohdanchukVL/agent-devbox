# devbox-db

Unified SQLite & PostgreSQL Schema Introspection and Safe Query MCP Server for **agent-devbox**.

Provides AI coding agents with direct, read-only access to local and remote databases to inspect schemas, table structures, relationships, and sample data—eliminating SQL and model hallucinations.

---

## Features

- **Multi-Database Support**:
  - **SQLite**: Zero-dependency via native Node 22 `node:sqlite`.
  - **PostgreSQL**: Enterprise-grade client via `pg`.
- **Auto-Discovery**:
  - Automatically locates `*.db` / `*.sqlite` files in your workspace.
  - Automatically reads `DATABASE_URL` from environment or `.env`.
- **Read-Only Safety**:
  - Rejects `DROP`, `DELETE`, `UPDATE`, `ALTER`, or multi-statement injections.
  - Enforces read-only transactions on PostgreSQL (`BEGIN READ ONLY`).
  - Automatic `LIMIT` clamping to prevent context window blowup.

---

## Available Tools

- `db_list_tables`: Lists all tables, views, and row counts.
- `db_describe_table`: Columns, types, nullability, primary keys, foreign keys, and indexes.
- `db_query`: Safe read-only SELECT execution formatted as markdown tables.
- `db_schema_dump`: Complete DDL schema dump for instant agent understanding.

---

## Integration

Registered in `~/.claude.json`:
```bash
claude mcp add -s user db -- /home/dev/.devbox/mcp/db/index.js
```
