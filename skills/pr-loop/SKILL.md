---
name: pr-loop
description: Drive the Codex review cycle on an open PR. Polls Codex comments, classifies severity (P0/P1 blocking, P2/nit ignored), applies fixes via subagent or escalates to a different worker on round 3, labels needs-human and stops on round 4. In Phase 1 stops at "ready to merge"; Phase 2 will auto-merge.
---

# pr-loop

Drives the Codex review cycle on an open PR until either all gates are green or the round cap is hit.

> **Phase 1 (current):** stops at "ready to merge" — the human clicks merge. Phase 2 flips on auto-merge.

## Inputs

- `pr_number` — the open draft PR
- (Implicit) `MCO_MAX_ROUNDS` (default 4), `MCO_TOKEN_BUDGET_USD`, `MCO_BLOCKING_SEVERITIES` (default `P0,P1`), `MCO_DRY_RUN`

## Per-round runbook

For `round` from 1 to `MCO_MAX_ROUNDS`:

### 1. Trigger the review

- **Round 1:** mark the PR ready for review (`gh pr ready <pr>`), then comment `@codex review`.
- **Round 2+:** comment `@codex review` again to request a re-review of the new commits.

If `MCO_DRY_RUN=1`, skip the actual `gh pr comment` and synthesize stub review data for downstream testing.

### 2. Poll for the review

Wait for a Codex review to land on the latest commit. Poll every 30s, up to a 15-minute ceiling:

```bash
gh pr view "$pr_number" --json reviews,comments,statusCheckRollup,headRefOid > "$round_dir/pr.json"
```

A review counts as "fresh" when `reviews[*].commit.oid == headRefOid` and the author is the Codex bot. If the ceiling expires, abort the round with `needs-human`.

### 3. Parse and classify comments

Walk `comments` + `reviews[*].body` looking for severity tags. Match `\b(P0|P1|P2|nit)\b` (case-insensitive) anywhere in the comment body — first match wins. Default to `P2` if nothing matches.

Filter to **blocking severities only** (`MCO_BLOCKING_SEVERITIES`, default `P0,P1`). Save:

```
.mco-cache/<pr>/round-<n>/comments.json     # all comments with severity tag attached
.mco-cache/<pr>/round-<n>/blocking.json     # filtered to blocking only
.mco-cache/<pr>/round-<n>/status.json       # statusCheckRollup snapshot
```

### 4. Stall detection

Compare `blocking.json` to round `n-1`'s `blocking.json` by comment ID (or, if IDs are unstable, by `(path, line, severity, body-hash)`). If **any** blocking comment ID appears in both → escalate to round-3 behavior immediately, even if the current round is 1 or 2.

### 5. Branch on round

| Round | Behavior |
|---|---|
| 1–2 | For each blocking comment, spawn `pr-loop-pr-fixer` subagent (Agent tool, `subagent_type: pr-loop-pr-fixer`). Pass it: PR number, comment ID, file path, line, body. The subagent commits a fix and writes `fix-<id>.md` to the round dir. After all subagents return, `git push`. |
| 3 | Build a single combined fix prompt (all blocking comments concatenated) and hand off to `route-task` with `round=3` and `exclude=<workers used in rounds 1–2>`. `route-task` picks a different worker, invokes it, pushes. |
| 4+ | Stop the loop. `gh pr edit "$pr_number" --add-label needs-human`. Post a summary comment listing all rounds, the blocking comments that survived, and the cache path. Return failure. |

If the **token / cost cap** (`MCO_TOKEN_BUDGET_USD`) is exceeded at any round, treat it identically to round 4 (label, comment, stop).

### 6. Re-check gates

After fix commits land, re-fetch the PR JSON and check the gates **before** triggering another Codex round:

- CI green (`statusCheckRollup[*].conclusion == 'SUCCESS'` for required checks)
- Tests green (subset of CI)
- Typecheck green (subset of CI)
- Lint green (subset of CI)
- Zero unresolved P0/P1 comments — i.e. `blocking.json` is empty after `gh pr review --comments` resolved-state check

If all are green: **proceed to "ready to merge"** (don't waste another Codex round).

If checks are still pending, wait for them; if any fail, treat the failure like a blocking comment for the next round.

## Terminal states

### Ready to merge (success)

Post a summary comment on the PR:

```
multi-cli-orchestrator: all gates green ✅

- Rounds run: <n>
- Workers used: <list>
- Blocking comments resolved: <count>
- Cache: .mco-cache/<pr>/

Phase 1 mode: human merges. Click "Merge pull request" to land.
```

Return success to the caller (`start-feature`). The caller is responsible for clearing `.mco-cache/_lock`.

### Needs-human (failure)

Apply the `needs-human` label, post a summary comment, return failure. Caller clears the lock.

## Subagent

`agents/claude-code/pr-fixer.md` and `agents/opencode/pr-fixer.md` — same role, two CLI-specific frontmatter variants. Registered as `pr-loop-pr-fixer` after the post-install bootstrap (`~/.agents/skills/start-feature/scripts/install-agents.sh`) runs. Keep both bodies in sync.

## State / cache layout

```
.mco-cache/<pr>/
  round-0/                    # initial implementation (route-task writes this)
    worker, rationale, prompt.md, <worker>.out, <worker>.err
  round-1/
    pr.json, comments.json, blocking.json, status.json
    fix-<comment-id>.md       # one per fix subagent invocation
  round-2/ ...
  round-3/                    # re-route via route-task; same shape as round-0
    worker, rationale, prompt.md, <worker>.out, <worker>.err
  round-4/                    # only exists if we hit the cap
    summary.md
```

Cache is best-effort. If it's missing or corrupt, reconstruct from the `gh` API.
