# devbox-code-intel

Token-efficient Code Intelligence MCP Server for **agent-devbox**.

Provides high-speed, token-saving navigation for **Rust**, **TypeScript/JavaScript**, **Go**, and **Python** using Universal Ctags and Ripgrep.

---

## Why this exists

AI coding agents (Claude Code, Antigravity, OpenCode) often burn thousands of tokens by reading full files with `cat` or searching blindly with `grep`. 

`devbox-code-intel` reduces context consumption by **70%–95%** by exposing precise structural tools:

| Tool | Purpose | Token Saving |
|---|---|---|
| `get_outline` | Extracts classes, functions, methods, traits, structs with line numbers | **~95%** vs reading full file |
| `find_definition` | Locates symbol definition and returns a 12-line preview snippet | **~90%** vs full grep + cat |
| `find_references` | Finds all call-sites/usages across the workspace (excluding build artifacts) | Zero noise |
| `find_files` | Fast file search respecting `.gitignore` | High precision |

---

## Tools Reference

### 1. `get_outline`
Extracts high-level symbol outline from any code file.
```json
{
  "path": "src/main.rs"
}
```

### 2. `find_definition`
Jumps directly to symbol declaration with surrounding context.
```json
{
  "symbol": "UserSession",
  "path": "src"
}
```

### 3. `find_references`
Locates all occurrences with whole-word matching.
```json
{
  "symbol": "calculateTax",
  "glob": "*.ts"
}
```

### 4. `find_files`
Finds files matching pattern without opening them.
```json
{
  "query": "config"
}
```

---

## Integration with Agents

### Claude Code
Registered in `~/.claude.json` (user scope):
```bash
claude mcp add -s user code-intel -- /home/dev/.devbox/mcp/code-intel/index.js
```

### Antigravity (AGY)
Registered in `~/.gemini/antigravity-cli/mcp.json`:
```json
{
  "mcpServers": {
    "code-intel": {
      "command": "node",
      "args": ["/home/dev/.devbox/mcp/code-intel/index.js"]
    }
  }
}
```
