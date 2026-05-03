#!/usr/bin/env bash
# invoke-worker.sh — single chokepoint for invoking a worker CLI.
#
# Today: shells out to the chosen CLI in the current working directory.
# Future: drop-in replacement for an A2A client wrapper. Keep the signature stable.
#
# Usage: invoke-worker.sh <worker> <prompt-file> [log-dir]
#   worker:      claude | codex | gemini | opencode | smart-worker
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
  echo "usage: $0 <claude|codex|gemini|opencode|smart-worker> <prompt-file> [log-dir]" >&2
  exit 2
fi

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "error: prompt file not found: $PROMPT_FILE" >&2
  exit 2
fi

PROMPT="$(cat "$PROMPT_FILE")"

# Helper to run OpenCode commands with billing fallback
run_opencode_cmd() {
  local cmd=("$@")
  
  if [[ "${MCO_DRY_RUN:-0}" == "1" ]]; then
    printf 'DRY RUN: '
    printf '%q ' "${cmd[@]}"
    printf '\n'
    return 0
  fi

  local temp_combined
  temp_combined=$(mktemp)
  local exit_code=0
  
  if ! "${cmd[@]}" >"$temp_combined" 2>&1; then
    exit_code=$?
  fi

  # Check for billing errors
  if grep -qiE "insufficient balance|recharge|suspended" "$temp_combined"; then
    echo "Warning: OpenCode billing issue detected." >&2
    rm -f "$temp_combined"
    return 126 # Specific code for billing fallback
  fi

  if [[ -n "$LOG_DIR" ]]; then
    mkdir -p "$LOG_DIR"
    cat "$temp_combined" >"$LOG_DIR/$WORKER.out"
    [[ "$exit_code" != "0" ]] && cat "$temp_combined" >"$LOG_DIR/$WORKER.err"
  fi
  
  cat "$temp_combined"
  rm -f "$temp_combined"
  return "$exit_code"
}

case "$WORKER" in
  claude)
    CMD=(npx -y @anthropic-ai/claude-code --dangerously-skip-permissions -p "$PROMPT")
    ;;
  codex)
    # L4 (Expert) — High-speed implementation (GPT-5.3)
    CMD=(opencode --pure run --dangerously-skip-permissions -m "openai/gpt-5.3-codex" "$PROMPT")
    if ! run_opencode_cmd "${CMD[@]}"; then
      [[ $? -eq 126 ]] && exec "$0" "smart-worker" "$PROMPT_FILE" "$LOG_DIR"
      exit $?
    fi
    exit 0
    ;;
  opencode)
    # L2 (Efficiency) — Default technical work (DeepSeek V4 Pro)
    CMD=(opencode --pure run --dangerously-skip-permissions -m "opencode-go/deepseek-v4-pro" "$PROMPT")
    if ! run_opencode_cmd "${CMD[@]}"; then
      [[ $? -eq 126 ]] && exec "$0" "smart-worker" "$PROMPT_FILE" "$LOG_DIR"
      exit $?
    fi
    exit 0
    ;;
  gemini)
    CMD=(gemini --approval-mode yolo -p "$PROMPT")
    ;;
  smart-worker)
    # L1 (Mechanical) — Budget-aware throughput tier.
    MODELS=(
      "opencode-go/kimi-k2.6"
      "opencode-go/qwen3.6-plus"
    )
    for MODEL in "${MODELS[@]}"; do
      echo "Attemping smart-worker implementation with $MODEL..." >&2
      CMD=(opencode --pure run --dangerously-skip-permissions -m "$MODEL" "$PROMPT")
      if run_opencode_cmd "${CMD[@]}"; then
        exit 0
      elif [[ $? -eq 126 ]]; then
        continue # Try next model if billing issue
      else
        echo "Warning: $MODEL failed, attempting fallback..." >&2
      fi
    done
    exit 1
    ;;
  *)
    echo "error: unknown worker: $WORKER" >&2
    exit 2
    ;;
esac

# Fallback for non-opencode workers (claude, gemini)
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
