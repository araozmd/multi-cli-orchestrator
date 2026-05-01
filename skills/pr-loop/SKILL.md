---
name: pr-loop
description: Drive the Codex review cycle on an open PR. Polls Codex comments, classifies severity (P0/P1 blocking, P2/nit ignored), applies fixes via subagent or escalates to a different worker on round 3, labels needs-human and stops on round 4. Auto-merges when all merge gates are green.
---

# pr-loop

> Status: scaffold. Implementation lands in Phase 1 per `docs/specs/2026-04-30-multi-cli-orchestrator-design.md`.

## Loop

1. Trigger Codex review (`@codex review` comment on the PR or wait for auto-review).
2. Poll `gh pr view <n> --json reviews,comments,statusCheckRollup` until the review completes.
3. Classify Codex comments:
   - **P0/P1** → blocking, must be addressed before merge
   - **P2/nit** → ignore for merge gating
4. Round-by-round behavior:
   - **Round 1–2:** spawn `pr-fixer` subagent per blocking comment, push commits.
   - **Round 3:** route the failing fix to a different worker (OpenCode or Gemini) for a different perspective.
   - **Round 4:** label PR `needs-human`, comment with iteration history, stop.
5. Stall detection: if the same P0/P1 comment reappears in two consecutive rounds, skip ahead to round 3 (different worker) early.

## Merge gates (all must pass)

- CI green
- Tests green
- Typecheck green
- Lint green
- Zero unresolved P0 or P1 Codex comments
- Branch protection enforced on `main`

When all green: auto-merge, archive the cache directory.

## Subagent

`agents/pr-fixer.md` — fixes one Codex comment per invocation in an isolated context.

## State

`.mco-cache/<pr-number>/` (gitignored): per-iteration artifacts — Codex comment dumps, fix summaries, last-known-good diffs.
