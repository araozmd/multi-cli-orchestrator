#!/usr/bin/env bash
# harness-delegate.sh — bridge between the SDD harness Builder phase and the
# multi-CLI orchestrator's worker + PR pipeline.
#
# The harness Builder, when harness.config.yaml has `execution.builder.backend:
# delegate`, invokes this as:
#     harness-delegate.sh <feature-id> <abs-spec-path>
#
# STAGE 1 — assemble the feature's 4-file spec (.spec/.plan/.tasks/.tests) into one
#   prompt and hand it to invoke-worker.sh (the stable worker chokepoint) to
#   produce the round-0 implementation. Worker selection is route-task's job in
#   production; here it defaults to `claude`, overridable via MCO_WORKER.
#
# STAGE 2 — commit the worker's changes on a feature branch, push, and open a
#   DRAFT PR whose body carries the spec + test plan (the Codex review checklist).
#   It then STOPS and hands the PR number back. The PR stays draft on purpose:
#   that is what gates auto-merge behind the LOCAL harness Reviewer. The
#   agent-driven review/merge cycle is NOT run here — see "HANDOFF" below.
#
# Everything honors MCO_DRY_RUN=1 (prints commands instead of running them; no
# branch, no commit, no push, no PR, no persistent lock). Exits non-zero on
# worker failure so the Builder can detect it.
#
# Env knobs: MCO_WORKER (default claude), MCO_BRANCH (default mco/<feature-id>),
#   MCO_PR_TITLE (default <feature-id>), MCO_CACHE_DIR (default .mco-cache).

set -euo pipefail

FEATURE_ID="${1:-}"
SPEC_PATH="${2:-}"
WORKER="${MCO_WORKER:-claude}"
DRY="${MCO_DRY_RUN:-0}"

if [[ -z "$FEATURE_ID" || -z "$SPEC_PATH" ]]; then
  echo "usage: $0 <feature-id> <abs-spec-path>" >&2
  exit 2
fi
if [[ ! -d "$SPEC_PATH" ]]; then
  echo "error: spec path not found or not a directory: $SPEC_PATH" >&2
  exit 2
fi

# Locate the worker chokepoint as a sibling of this script (cwd-independent).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVOKE_WORKER="$SCRIPT_DIR/invoke-worker.sh"
if [[ ! -f "$INVOKE_WORKER" ]]; then
  echo "error: invoke-worker.sh not found next to this script ($INVOKE_WORKER)" >&2
  exit 2
fi

# run <cmd...> — execute, or print under dry-run. For side-effecting commands only.
run() {
  if [[ "$DRY" == "1" ]]; then
    printf 'DRY RUN: '; printf '%q ' "$@"; printf '\n'
    return 0
  fi
  "$@"
}

CACHE_ROOT="${MCO_CACHE_DIR:-.mco-cache}"
WORKDIR="$CACHE_ROOT/$FEATURE_ID"
ROUND0="$WORKDIR/round-0"
mkdir -p "$ROUND0"

# ── Concurrency lock (sequential invariant) ───────────────────────────────────
# Phase 1 is strictly sequential — one feature in flight at a time. Claim the
# lock ATOMICALLY before STAGE 1 (the worker runs for minutes; a check-now/
# write-later split is a TOCTOU race that lets two delegates share a worktree).
# noclobber makes the check-and-create one indivisible step. Dry-run stays lock-free.
LOCK="$CACHE_ROOT/_lock"
if [[ "$DRY" != "1" ]]; then
  if ! ( set -o noclobber; : > "$LOCK" ) 2>/dev/null; then
    echo "error: another feature is in flight ($(tr '\n' ' ' < "$LOCK" 2>/dev/null))." >&2
    echo "       finish/abort it, or force-clear with: rm $LOCK" >&2
    exit 3
  fi
  printf 'feature=%s\nworker=%s\n' "$FEATURE_ID" "$WORKER" > "$LOCK"
fi

# ── STAGE 1: assemble spec → worker ───────────────────────────────────────────
PROMPT_FILE="$ROUND0/prompt.md"
{
  echo "# Implement feature: $FEATURE_ID"
  echo
  echo "You are implementing an APPROVED Spec-Driven-Development feature. The full"
  echo "contract follows (spec / plan / tasks / tests). Implement every task, write"
  echo "the tests so each R-id is covered, and stay strictly inside the spec — if"
  echo "the spec is wrong or incomplete, stop and report rather than redesigning."
  echo
  found=0
  for part in spec plan tasks tests; do
    for match in "$SPEC_PATH"/*."$part".md; do
      [[ -f "$match" ]] || continue
      found=1
      echo "---"
      echo "## $(basename "$match")"
      echo
      cat "$match"
      echo
    done
  done
  [[ "$found" -eq 1 ]] || echo "(warning: no .spec/.plan/.tasks/.tests files found in $SPEC_PATH)"
} > "$PROMPT_FILE"

# round-0 provenance, in the layout pr-loop expects.
echo "$WORKER" > "$ROUND0/worker"
echo "delegated by harness Builder (execution.builder.backend=delegate); worker via ${MCO_WORKER:+MCO_WORKER}${MCO_WORKER:-route-task default}" > "$ROUND0/rationale"

echo "→ assembled spec prompt: $PROMPT_FILE ($(wc -l < "$PROMPT_FILE" | tr -d ' ') lines)" >&2
echo "→ delegating feature '$FEATURE_ID' to worker '$WORKER'" >&2

rc=0
bash "$INVOKE_WORKER" "$WORKER" "$PROMPT_FILE" "$ROUND0" || rc=$?
if [[ "$rc" -ne 0 ]]; then
  echo "✗ worker '$WORKER' failed (rc=$rc); not opening a PR. See $ROUND0/." >&2
  # No PR was opened — release the lock so a failed run doesn't block the next feature.
  [[ "$DRY" != "1" ]] && rm -f "$LOCK"
  exit "$rc"
fi

# ── STAGE 2: branch → commit → push → draft PR ────────────────────────────────
BRANCH="${MCO_BRANCH:-mco/$FEATURE_ID}"
PR_TITLE="${MCO_PR_TITLE:-$FEATURE_ID}"

# PR body = spec + test plan (the Codex review checklist) + orchestration note.
PR_BODY_FILE="$WORKDIR/pr-body.md"
{
  echo "## Spec"
  for m in "$SPEC_PATH"/*.spec.md; do [[ -f "$m" ]] && cat "$m"; done
  echo
  echo "## Test plan / Codex review checklist"
  for m in "$SPEC_PATH"/*.tests.md; do [[ -f "$m" ]] && cat "$m"; done
  echo
  echo "## Multi-CLI orchestration"
  echo "- Feature: \`$FEATURE_ID\` — implemented by worker \`$WORKER\` (round-0, via harness delegate)"
  echo "- Draft on purpose: awaiting the LOCAL harness Reviewer (pre-merge gate), then \`pr-loop\` (Codex + auto-merge)"
  echo "- Cache: \`$WORKDIR/\`"
} > "$PR_BODY_FILE"

run git checkout -b "$BRANCH"
run git add -A
run git commit -m "✨ $FEATURE_ID: implement via delegated worker ($WORKER)"
run git push -u origin "$BRANCH"

if [[ "$DRY" == "1" ]]; then
  echo "DRY RUN: gh pr create --draft --title $(printf '%q' "$PR_TITLE") --body-file $(printf '%q' "$PR_BODY_FILE")"
  PR_NUMBER="DRYRUN"
else
  # Lock was already claimed before STAGE 1; append PR provenance (don't clobber).
  { echo "branch=$BRANCH"; } >> "$LOCK"
  PR_URL="$(gh pr create --draft --title "$PR_TITLE" --body-file "$PR_BODY_FILE")"
  PR_NUMBER="$(echo "$PR_URL" | grep -oE '[0-9]+$')"
  # Relocate cache to the PR-keyed layout pr-loop reads (.mco-cache/<pr>/round-0/).
  if [[ -n "$PR_NUMBER" && ! -d "$CACHE_ROOT/$PR_NUMBER" ]]; then
    mv "$WORKDIR" "$CACHE_ROOT/$PR_NUMBER"
    WORKDIR="$CACHE_ROOT/$PR_NUMBER"
  fi
  { echo "pr=$PR_NUMBER"; echo "url=$PR_URL"; } >> "$LOCK"
  echo "→ opened draft PR #$PR_NUMBER — $PR_URL" >&2
fi

# ── HANDOFF (agent-driven, not this script) ───────────────────────────────────
# The deterministic part ends here. The Builder/Orchestrator now:
#   1. runs the LOCAL harness Reviewer against branch '$BRANCH' (pre-merge gate);
#   2. on local approval, invokes the `pr-loop` skill with PR #$PR_NUMBER, which
#      `gh pr ready`s it, runs the Codex cycle, and auto-merges when green;
#   3. the merge is what flips the feature to `done` and clears $LOCK.
# Emit a machine-readable handoff line for the caller to parse.
echo "MCO_DELEGATE_RESULT feature=$FEATURE_ID worker=$WORKER branch=$BRANCH pr=$PR_NUMBER cache=$WORKDIR"
exit 0
