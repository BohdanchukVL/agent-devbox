#!/usr/bin/env bash
# devbox-memory — wrapper for @modelcontextprotocol/server-memory that routes
# each project to its own memory file based on the git repository root.
#
# Usage: claude mcp add memory -- devbox-memory
#
# If cwd is inside a git repository, memory is stored at
#   <git-root>/.devbox/memory.jsonl
# Otherwise, it falls back to ~/.devbox/memory.jsonl

set -euo pipefail

# Determine project-specific memory file location
if git_root=$(git rev-parse --show-toplevel 2>/dev/null); then
  MEMORY_DIR="$git_root/.devbox"
else
  MEMORY_DIR="${HOME}/.devbox"
fi

mkdir -p "$MEMORY_DIR"
export MEMORY_FILE_PATH="$MEMORY_DIR/memory.jsonl"

exec mcp-server-memory "$@"
