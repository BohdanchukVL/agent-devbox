# Agent Devbox Guidelines: Token & Context Optimization

## Code Navigation & Search Rules
- **DO NOT** read entire files with `cat` or broad file-viewing tools when exploring or searching for code symbols.
- **File Structure**: ALWAYS use `code-intel:get_outline` to inspect classes, functions, methods, traits, structs, and line numbers before opening or editing a file.
- **Symbol Definitions**: ALWAYS use `code-intel:find_definition` to locate function, struct, class, or type definitions. It returns the exact file, line number, and a 12-line preview snippet of the definition.
- **Symbol Usages**: Use `code-intel:find_references` to find call-sites across the codebase. It automatically ignores noisy build directories (`target/`, `node_modules/`, `vendor/`, `.git/`, `.venv/`).
- **AST Pattern Matching**: Use `ast-grep:find_code` or `ast-grep:rewrite_code` for syntax-aware pattern searches and structural refactoring across Rust, TypeScript, JavaScript, Go, and Python.
- **Terminal Execution**: Keep command output concise. Pipe long outputs through `head`, `tail`, or `grep` to prevent context bloating.
