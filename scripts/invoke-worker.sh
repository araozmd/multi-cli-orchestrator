#!/usr/bin/env bash
# invoke-worker.sh — single chokepoint for invoking a worker CLI.
#
# Today: shells out to the chosen CLI in the current working directory.
# Future: drop-in replacement for an A2A client wrapper. Keep the signature stable.
#
# Usage: invoke-worker.sh <worker> <prompt-file> [log-dir]
#   worker:      claude | opencode | gemini
#   prompt-file: path to a file containing the task prompt
#   log-dir:     optional directory; if set, stdout/stderr captured to <log-dir>/<worker>.{out,err}
#
# Honors MCO_DRY_RUN=1 (prints the command instead of running it).
# Exits non-zero on worker failure so callers can detect it.

set -euo pipefail

WORKER="${1:-}"
PROMPT_FILE="${2:-}"
LOG_DIR="${3:-}"

if [[ -z "$WORKER" || -z "$PROMPT_FILE" ]]; then
  echo "usage: $0 <claude|opencode|gemini> <prompt-file> [log-dir]" >&2
  exit 2
fi

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "error: prompt file not found: $PROMPT_FILE" >&2
  exit 2
fi

PROMPT="$(cat "$PROMPT_FILE")"

case "$WORKER" in
  claude)   CMD=(npx -y @anthropic-ai/claude-code -p "$PROMPT") ;;
  opencode) CMD=(opencode run "$PROMPT") ;;
  gemini)   CMD=(gemini -p "$PROMPT") ;;
  *)        echo "error: unknown worker: $WORKER" >&2; exit 2 ;;
esac

if [[ "${MCO_DRY_RUN:-0}" == "1" ]]; then
  printf 'DRY RUN: '
  printf '%q ' "${CMD[@]}"
  printf '\n'
  exit 0
fi

if [[ -n "$LOG_DIR" ]]; then
  mkdir -p "$LOG_DIR"
  "${CMD[@]}" >"$LOG_DIR/$WORKER.out" 2>"$LOG_DIR/$WORKER.err"
else
  "${CMD[@]}"
fi
