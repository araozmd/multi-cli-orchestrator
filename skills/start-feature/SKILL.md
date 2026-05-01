---
name: start-feature
description: Entry point for the multi-CLI orchestration workflow. Use when the user wants to build a new feature, fix a bug, or make a non-trivial change. Brainstorms the spec, generates a test plan, opens a PR, hands off to the routing skill, and triggers the PR review loop.
---

# start-feature

Entry point for the multi-CLI orchestration loop. Drives a feature from "I want X" through Codex-reviewed, gates-green, ready-to-merge.

> **Phase 1 (current):** human merges the final PR. Auto-merge lands in Phase 2 — see `docs/specs/2026-04-30-multi-cli-orchestrator-design.md`.

## When to use

Trigger when the user describes a feature, bug, or change that warrants a PR. Skip for read-only questions, exploratory chats, or trivial in-place edits.

## Preconditions to check first

1. `gh auth status` — fail fast with a clear message if not logged in.
2. `git status --porcelain` is empty — refuse to start on a dirty tree (commit/stash first).
3. `git rev-parse --abbrev-ref HEAD` — warn if not on `main` (or the configured default branch).
4. **Lock check:** if `.mco-cache/_lock` exists, read it and refuse with the message:
   > "Another feature is in flight: <branch> (PR #<n>). Finish or abort that one first. To force-clear the lock: `rm .mco-cache/_lock`."

## Runbook

### Step 1 — Brainstorm the spec

Invoke the global `brainstorming` skill on the user's description. Output: a short markdown spec covering goal, scope, non-goals, and the smallest user-visible change that would close the work. Save to `.mco-cache/pending/spec.md`.

### Step 2 — Generate the test plan

Working from the spec, produce a checklist of testable acceptance criteria. **This list doubles as the Codex review checklist** (it gets pasted into the PR description so Codex reviews against it). Each item should be a single observable behavior, not "write unit tests for X."

Save to `.mco-cache/pending/test-plan.md`.

Show both files to the user, ask "ready to open the PR?" — wait for confirmation before any branch/PR creation.

### Step 3 — Branch + lock

```bash
slug=$(<derive from spec title, kebab-case, max 40 chars>)
git checkout -b "feat/$slug"
mkdir -p .mco-cache
echo "branch=feat/$slug" > .mco-cache/_lock
echo "started=$(date -u +%FT%TZ)" >> .mco-cache/_lock
```

### Step 4 — Open draft PR

Compose the PR body from spec + test plan:

```markdown
## Spec
<contents of pending/spec.md>

## Test plan / Codex review checklist
<contents of pending/test-plan.md>

## Multi-CLI orchestration
- Status: in flight via `pr-loop`
- Cache: `.mco-cache/<pr-number>/`
```

If `MCO_DRY_RUN=1`, skip the actual `gh pr create` and synthesize a fake PR number for downstream testing.

```bash
git push -u origin "feat/$slug"
pr_url=$(gh pr create --draft --title "<title from spec>" --body-file <(cat .mco-cache/pending/spec.md .mco-cache/pending/test-plan.md))
pr_number=$(echo "$pr_url" | grep -oE '[0-9]+$')
mkdir -p ".mco-cache/$pr_number/round-0"
mv .mco-cache/pending/* ".mco-cache/$pr_number/"
echo "pr=$pr_number" >> .mco-cache/_lock
echo "url=$pr_url" >> .mco-cache/_lock
```

### Step 5 — Hand off to `route-task`

Invoke the `route-task` skill with:
- The spec file path
- The PR number
- The round number (`0` for initial implementation)

`route-task` will pick the worker, write the worker prompt, call `~/.agents/skills/start-feature/scripts/invoke-worker.sh` (the orchestrator's single-chokepoint harness), capture commits, push.

### Step 6 — Hand off to `pr-loop`

Invoke the `pr-loop` skill with the PR number. It drives the Codex review cycle until either:
- All gates green → posts "ready to merge" comment, returns success → **clear `.mco-cache/_lock`**, tell the user to merge.
- `needs-human` label applied → returns failure → leave the lock in place, tell the user what intervened.

## Lock cleanup contract

`start-feature` is responsible for removing `.mco-cache/_lock` on every terminal outcome (success, `needs-human`, user abort). If `pr-loop` returns either way, clear the lock before returning control to the user.

## Configuration

- `MCO_MAX_ROUNDS` (default 4) — passed through to `pr-loop`
- `MCO_TOKEN_BUDGET_USD` — passed through to `pr-loop`
- `MCO_DRY_RUN=1` — no PR opened, no commits pushed, no Codex trigger; useful for end-to-end pipeline testing
