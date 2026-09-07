# Agent Devbox Guidelines: Token & Context Optimization

## Code Navigation & Search Rules
- **DO NOT** read entire files with `cat` or broad file-viewing tools when exploring or searching for code symbols.
- **File Structure**: ALWAYS use `code-intel:get_outline` to inspect classes, functions, methods, traits, structs, and line numbers before opening or editing a file.
- **Symbol Definitions**: ALWAYS use `code-intel:find_definition` to locate function, struct, class, or type definitions. It returns the exact file, line number, and a 12-line preview snippet of the definition.
- **Symbol Usages**: Use `code-intel:find_references` to find call-sites across the codebase. It automatically ignores noisy build directories (`target/`, `node_modules/`, `vendor/`, `.git/`, `.venv/`).
- **AST Pattern Matching**: Use `ast-grep:find_code` or `ast-grep:rewrite_code` for syntax-aware pattern searches and structural refactoring across Rust, TypeScript, JavaScript, Go, and Python.
- **Terminal Execution**: Keep command output concise. Pipe long outputs through `head`, `tail`, or `grep` to prevent context bloating.

## Persistent Memory & Project Knowledge
- **Recall**: When starting a task, query `memory:search_nodes` or `memory:read_graph` to retrieve architectural decisions, preferred conventions, and past context.
- **Record**: When an architectural decision, library choice, or critical pattern is agreed upon, proactively persist it using `memory:create_entities` and `memory:add_observations`.

## Database & Schema Introspection
- **Zero-Guessing Schema**: Before writing SQL queries, ORM models, or migrations, ALWAYS run `db:db_list_tables` and `db:db_describe_table` to inspect exact table layouts, column types, and foreign keys.
- **Safe Queries**: Use `db:db_query` to verify data structures with read-only SELECT queries.

## Web & UI Testing
- **Closed Loop Verification**: When building web applications or APIs, use `playwright:browser_navigate` and `playwright:browser_snapshot` (accessibility tree) to verify pages, click buttons, and inspect console errors autonomously before asking for human review.
