#!/usr/bin/env bash
# invoke-worker.sh — single chokepoint for invoking a worker CLI.
#
# Today: shells out to the chosen CLI.
# Future: drop-in replacement for an A2A client wrapper. Keep the signature stable.
#
# Usage: invoke-worker.sh <worker> <prompt-file>
#   worker:      claude | opencode | gemini
#   prompt-file: path to a file containing the task prompt
#
# Status: scaffold. Implementation lands in Phase 1 per docs/specs/2026-04-30-multi-cli-orchestrator-design.md.

set -euo pipefail

WORKER="${1:-}"
PROMPT_FILE="${2:-}"

if [[ -z "$WORKER" || -z "$PROMPT_FILE" ]]; then
  echo "usage: $0 <claude|opencode|gemini> <prompt-file>" >&2
  exit 2
fi

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "error: prompt file not found: $PROMPT_FILE" >&2
  exit 2
fi

case "$WORKER" in
  claude)   echo "TODO: claude --bare -p \"\$(cat $PROMPT_FILE)\"" ;;
  opencode) echo "TODO: opencode run --prompt-file $PROMPT_FILE" ;;
  gemini)   echo "TODO: gemini -p \"\$(cat $PROMPT_FILE)\"" ;;
  *)        echo "error: unknown worker: $WORKER" >&2; exit 2 ;;
esac
