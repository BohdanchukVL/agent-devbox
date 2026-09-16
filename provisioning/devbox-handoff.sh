#!/usr/bin/env bash
set -euo pipefail

# devbox-handoff: Generate structured task checkpoints for agent handoffs
# Usage: devbox-handoff [--json] [--prompt] [repo_path]

JSON_MODE=false
PROMPT_MODE=false
TARGET_DIR="${PWD}"

for arg in "$@"; do
  case "$arg" in
    --json)
      JSON_MODE=true
      ;;
    --prompt)
      PROMPT_MODE=true
      ;;
    -h|--help)
      echo "Usage: devbox-handoff [--json] [--prompt] [path]"
      echo "Generates a structured git & task context checkpoint for seamless LLM handoffs."
      exit 0
      ;;
    *)
      if [ -d "$arg" ]; then
        TARGET_DIR="$arg"
      fi
      ;;
  esac
done

cd "$TARGET_DIR"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ "$JSON_MODE" = "true" ]; then
    echo '{"error": "Not inside a git repository", "path": "'"$TARGET_DIR"'"}'
  else
    echo "devbox-handoff: $TARGET_DIR is not inside a git repository."
  fi
  exit 1
fi

GIT_ROOT=$(git rev-parse --show-toplevel)
REPO_NAME=$(basename "$GIT_ROOT")
BRANCH=$(git branch --show-current 2>/dev/null || echo "DETACHED")
COMMIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "INITIAL")
COMMIT_MSG=$(git log -1 --pretty=%s 2>/dev/null || echo "No commits yet")

STATUS_SHORT=$(git status --short)
DIRTY_COUNT=$(echo -n "$STATUS_SHORT" | grep -c . || true)
DIFF_STAT=$(git diff --stat HEAD 2>/dev/null || git diff --stat 2>/dev/null || true)
LOG_RECENT=$(git log -n 3 --oneline 2>/dev/null || echo "No commit history")

# Check if tests were recently recorded in memory
MEMORY_FILE="$GIT_ROOT/.devbox/memory.jsonl"
LAST_MEMORY=""
if [ -f "$MEMORY_FILE" ]; then
  LAST_MEMORY=$(tail -n 1 "$MEMORY_FILE" 2>/dev/null || true)
fi

if [ "$JSON_MODE" = "true" ]; then
  python3 -c "
import json, sys

data = {
    'repository': sys.argv[1],
    'root': sys.argv[2],
    'branch': sys.argv[3],
    'commit': sys.argv[4],
    'commit_message': sys.argv[5],
    'dirty_files_count': int(sys.argv[6]),
    'status_short': sys.argv[7],
    'diff_stat': sys.argv[8],
    'recent_commits': sys.argv[9].splitlines(),
    'last_memory': sys.argv[10]
}
print(json.dumps(data, indent=2))
" "$REPO_NAME" "$GIT_ROOT" "$BRANCH" "$COMMIT_SHA" "$COMMIT_MSG" "$DIRTY_COUNT" "$STATUS_SHORT" "$DIFF_STAT" "$LOG_RECENT" "$LAST_MEMORY"
  exit 0
fi

cat <<EOF
# Task Handoff Checkpoint

- **Repository**: \`$REPO_NAME\` (\`$GIT_ROOT\`)
- **Branch**: \`$BRANCH\` | **HEAD**: \`$COMMIT_SHA\` ("$COMMIT_MSG")
- **Dirty Files**: $DIRTY_COUNT modified/untracked

## Working Tree Status
\`\`\`
${STATUS_SHORT:-"(working tree clean)"}
\`\`\`

## Diff Stat
\`\`\`
${DIFF_STAT:-"(no unstaged/staged diff)"}
\`\`\`

## Recent Commits
\`\`\`
$LOG_RECENT
\`\`\`
EOF

if [ -n "$LAST_MEMORY" ]; then
  echo ""
  echo "## Last Recorded Task Memory"
  echo "\`\`\`json"
  echo "$LAST_MEMORY"
  echo "\`\`\`"
fi

if [ "$PROMPT_MODE" = "true" ]; then
  echo ""
  echo "---"
  echo "**Handoff Instruction for Incoming Agent**:"
  echo "1. Review the modified files and commit history above."
  echo "2. Run the repository test suite to verify the current state."
  echo "3. Continue the task according to the project invariants in CLAUDE.md / AGENTS.md."
fi
