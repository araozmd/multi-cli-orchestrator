---
name: pr-loop
description: Drive the Codex review cycle on an open PR. Polls Codex comments, classifies severity (P0/P1 blocking, P2/nit ignored), applies fixes via subagent or escalates to a different worker on round 3, labels needs-human and stops on round 4. Auto-merges when all gates are green.
---

# pr-loop

Drives the Codex review cycle on an open PR until either all gates are green or the round cap is hit.

> **Auto-merge enabled.** When all gates are green, the orchestrator merges the PR automatically.

## Inputs

- `pr_number` — the open draft PR
- (Implicit) `MCO_MAX_ROUNDS` (default 4), `MCO_TOKEN_BUDGET_USD`, `MCO_BLOCKING_SEVERITIES` (default `P0,P1`), `MCO_DRY_RUN`, `MCO_MERGE_STRATEGY` (default `merge`), `MCO_POLL_INTERVAL` (default 60s — Codex poll cadence), `MCO_POLL_CEILING` (default 900s — review wait ceiling)

## Per-round runbook

For `round` from 1 to `MCO_MAX_ROUNDS`:

### 1. Trigger the review

First resolve the repo slug (used by the `gh api` calls in step 2):

```bash
read -r owner repo < <(gh repo view --json owner,name --jq '"\(.owner.login) \(.name)"')
```

- **Round 1:** mark the PR ready for review (`gh pr ready <pr>`), then comment `@codex review`.
- **Round 2+:** comment `@codex review` again to request a re-review of the new commits.

**Capture the triggering comment's id** so step 2 can poll its reactions for the 👍-only (clean) case:

```bash
trigger_comment_id=$(gh api "repos/$owner/$repo/issues/$pr_number/comments" \
  --jq 'map(select(.body | contains("@codex review"))) | last | .id')
```

If `MCO_DRY_RUN=1`, skip the actual `gh pr comment` and synthesize stub review data for downstream testing.

### 2. Poll for the review (background watcher)

Wait for a Codex review to land on the latest commit. **Do not poll by hand.** A by-hand poll is why landed Codex comments get missed: in an interactive session you fetch the review state once, see nothing yet, and the turn ends — so a review that lands minutes later goes unnoticed until a human nudges "review again". Foreground `sleep` is also blocked in this harness, so an inline "sleep 30; check; repeat" can't run either.

Instead, launch the background watcher and let the harness wake you when it exits:

```bash
# Bash tool, run_in_background: true — keeps polling across turns, re-invokes you on exit
bash ~/.agents/skills/pr-loop/scripts/wait-for-codex.sh \
  "$pr_number" "$trigger_comment_id" "$round_dir"
```

The watcher polls every `MCO_POLL_INTERVAL` seconds (default **60** — minute-by-minute) up to `MCO_POLL_CEILING` (default **900** = 15 min). It writes the **three sources** into `$round_dir` on each poll (`gh pr view` alone does NOT return Codex's findings):

- `pr.json` — `gh pr view --json reviews,comments,statusCheckRollup,headRefOid` (summary, checks, head oid)
- `review-comments.json` — `gh api repos/<o>/<r>/pulls/<n>/comments --paginate --slurp` flattened to one array — **the inline findings**, anchored to file/line. Returned by **neither** `--json comments` (issue comments only) **nor** `reviews[*].body` (summary banner only). `--slurp` is required so paginated REST results remain parseable when more than one page is returned.
- `issue-comments.json` — `gh api repos/<o>/<r>/issues/<n>/comments --paginate --slurp` — the issue-comment stream, scanned by condition 2b for a clean banner. Fetched via paginated REST (not `gh pr view --json comments`, which caps at `first:100`) so a banner posted past the first 100 comments is still caught.
- `reactions.json` — reactions on the `@codex review` comment (Codex reacts 👍 when it has nothing).

When the watcher exits, the harness re-invokes you. **Branch on its exit code** — do not re-poll:

| Exit | Meaning | Next |
|---|---|---|
| `0` | Review **with findings** landed on the head commit | Go to step 3, classify `review-comments.json` |
| `3` | **Clean review, 0 findings** (head banner as a review **or** issue comment, or 👍 reaction) | Skip classify; treat round as zero blocking |
| `2` | **Timeout** — ceiling hit, no resolution | Abort round with `needs-human`. Do **not** treat a timeout as "clean." |
| `4` | Usage / precondition error | Fix args and relaunch |

The exit codes encode the same freshness conditions the watcher checks: (1) Codex-bot inline comments filed against `headRefOid` **and created at/after the trigger comment** → findings; (2) summary banner containing `Reviewed commit: <short headRefOid>` with zero head findings → clean; (2b) that same head banner delivered as an **issue comment** rather than a review → clean; (3) Codex-bot 👍 (`+1`) on the trigger comment → clean.

**Two freshness pitfalls the watcher guards against** (both previously stalled clean PRs):
- **Re-anchored stale threads.** GitHub re-stamps old unresolved threads' `commit_id` to each new head, so a stale thread's `commit_id` matches `headRefOid` even though it predates this round. Condition 1 counts an inline comment only when `created_at >= trigger.created_at`, so re-anchored old threads no longer masquerade as fresh findings.
- **Clean banner as an issue comment.** Codex's zero-findings result (“Didn't find any major issues. Breezy!” + `Reviewed commit: <head>`) posts to `.comments[]`, which conditions 1/2 never scan. Condition 2b scans issue comments for the head banner so a genuinely clean PR resolves instead of waiting out the ceiling.

**Codex bot identity.** The watcher matches author login `chatgpt-codex-connector` with an **optional `[bot]` suffix** via prefix match — `gh pr view` (GraphQL) reports `chatgpt-codex-connector`; the REST API reports `chatgpt-codex-connector[bot]`. Treat both as the bot; never use an exact literal.

> **Dry run / no background tool.** If you can't background (e.g. `MCO_DRY_RUN=1`), the watcher still runs foreground and exits with the same codes — it just blocks until resolution or ceiling.

### 3. Parse and classify comments

Walk **`review-comments.json` (the inline findings)** + `reviews[*].body` + `comments` looking for severity tags. Codex tags severity as a **badge image**, not bare text — e.g. `![P2 Badge](https://img.shields.io/badge/P2-yellow?style=flat)`. Match `\b(P0|P1|P2|nit)\b` (case-insensitive) anywhere in the comment body — this catches both the badge alt-text/URL form and any bare-text form — first match wins. Default to `P2` if nothing matches.

**Only FRESH inline comments count for this round** — same freshness guard the watcher applies (see step 2). An inline comment counts only when it is filed against the head commit **and** its `created_at >= trigger.created_at`; otherwise a stale thread GitHub re-anchored to head slips back into `blocking.json` and defeats the guard. The watcher persists the anchor to `trigger-ts.txt`; apply it when reading the unfiltered `review-comments.json`:

```bash
since=$(cat "$round_dir/trigger-ts.txt" 2>/dev/null)
head=$(jq -r '.headRefOid' "$round_dir/pr.json")
jq --arg h "$head" --arg since "$since" '
  [ .[] | select((.commit_id // "") == $h)
        | select($since == "" or ((.created_at // "") >= $since)) ]' \
  "$round_dir/review-comments.json" > "$round_dir/fresh-comments.json"
# classify severities from fresh-comments.json (not the raw review-comments.json)
```

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

**Always write the worker file for this round** (so the handover summary is reconstructible from cache):

```bash
# rounds 1–2: pr-fixer subagents run in the orchestrator's active session (e.g., claude or agy)
# round 3: route-task already wrote it; this is a no-op overwrite
echo "<worker>" > "$round_dir/worker"
echo "<role>" > "$round_dir/role"  # implementation | fix | escalation
```

Use the active orchestrator (e.g., `claude` or `agy`) for rounds 1–2 (pr-fixer is a subagent). Use whatever `route-task` returned for round 3.

If the **token / cost cap** (`MCO_TOKEN_BUDGET_USD`) is exceeded at any round, treat it identically to round 4 (label, comment, stop).

### 6. Re-check gates

After fix commits land, re-fetch the PR JSON and check the gates **before** triggering another Codex round:

- CI green (`statusCheckRollup[*].conclusion == 'SUCCESS'` for required checks)
- Tests green (subset of CI)
- Typecheck green (subset of CI)
- Lint green (subset of CI)
- Zero unresolved P0/P1 comments — i.e. `blocking.json` is empty after `gh pr review --comments` resolved-state check

If all are green: **proceed to "ready to merge"** (don't waste another Codex round).

#### Squash-Merge Prep (if `MCO_MERGE_STRATEGY=squash`)

If squashing is enabled, invoke `@codex review` one last time with a specific instruction to **summarize the development journey** for a commit message.

```bash
gh pr comment "$pr_number" --body "@codex summarize: generate a high-signal squash commit message. Include the core implementation goal, which workers (Claude, OpenCode, Gemini) were used for which rounds, and a list of key P0/P1 fixes resolved. Output raw text only."
```

Poll for this summary (wait for a comment from `@codex` containing the summary), then save it to `.mco-cache/<pr>/squash-message.txt`.

If checks are still pending, wait for them; if any fail, treat the failure like a blocking comment for the next round.

## Handover summary

Before posting either terminal-state comment, build the handover summary by walking the cache:

```bash
# Per-round breakdown
for d in .mco-cache/<pr>/round-*/; do
  n=$(basename "$d" | sed 's/round-//')
  worker=$(cat "$d/worker" 2>/dev/null || echo "?")
  role=$(cat "$d/role" 2>/dev/null || echo "?")
  echo "- round-$n: $worker ($role)"
done

# Totals per worker
for d in .mco-cache/<pr>/round-*/; do cat "$d/worker" 2>/dev/null; done \
  | sort | uniq -c
```

Save the rendered summary to `.mco-cache/<pr>/handover-summary.md` so `start-feature` can read it after `pr-loop` returns.

## Terminal states

### Ready to merge (success)

Post a summary comment on the PR:

```
multi-cli-orchestrator: all gates green ✅

Handover summary:
- Rounds run: <n>
- Worker totals: claude=<a>, opencode=<b>, gemini=<c>, codex=<d>
- Round-by-round:
  • round-0: <worker> (implementation)
  • round-1: claude (fix x<count>)
  • ...
- Blocking comments resolved: <count>
- Cache: .mco-cache/<pr>/
```

**Resolve Codex threads first — never human ones.** The repo ruleset requires every review thread resolved before merge, but the loop may only auto-resolve threads **it owns** (opened by the Codex bot). Auto-resolving a human reviewer's unresolved conversation would silently bypass the merge gate that keeps human feedback meaningful. So: fetch each unresolved thread with its first-comment author; if **any** non-Codex thread is unresolved, **stop and go to the needs-human terminal state** (do not merge). Only when every remaining unresolved thread is Codex-owned do we resolve them (via the GraphQL `resolveReviewThread` mutation — there is no REST/`gh pr` equivalent) and proceed.

```bash
read -r owner repo < <(gh repo view --json owner,name --jq '"\(.owner.login) \(.name)"')
codex_bot="chatgpt-codex-connector"   # prefix-match; REST/GraphQL may add a [bot] suffix

# Unresolved threads as "<id> <first-comment-author-login>" (paginated).
unresolved=$(gh api graphql -f query='
  query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String){
    repository(owner:$owner,name:$repo){
      pullRequest(number:$pr){
        reviewThreads(first:100,after:$endCursor){
          nodes{ id isResolved comments(first:1){ nodes{ author{ login } } } }
          pageInfo{ hasNextPage endCursor }
        }}}}' \
  -f owner="$owner" -f repo="$repo" -F pr="$pr_number" --paginate \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[]
        | select(.isResolved | not)
        | "\(.id) \(.comments.nodes[0].author.login // "")"')

# Any unresolved thread NOT opened by Codex → hand to a human, do NOT merge.
non_codex=$(printf '%s\n' "$unresolved" | grep -v " ${codex_bot}" | grep -v '^$' || true)
if [[ -n "$non_codex" ]]; then
  merge_ok=0                                                 # → needs-human terminal state
else
  merge_ok=1
  while read -r tid _author; do
    [[ -z "$tid" ]] && continue
    gh api graphql -f query='
      mutation($id:ID!){ resolveReviewThread(input:{threadId:$id}){ thread{ id isResolved } } }' \
      -f id="$tid" >/dev/null
  done <<< "$unresolved"
fi
```

**If `merge_ok=0`, stop here** — go straight to the [needs-human terminal state](#needs-human-failure) and run **none** of the merge commands below. Only proceed when `merge_ok=1`.

Then auto-merge (guarded), deleting the remote branch in the same call:

```bash
if [[ "${merge_ok:-0}" != "1" ]]; then
  echo "unresolved non-Codex threads remain — needs-human, not merging" >&2   # do not merge
elif [[ "${MCO_MERGE_STRATEGY:-merge}" == "squash" ]]; then
  gh pr merge "$pr_number" --squash --delete-branch --body-file ".mco-cache/$pr_number/squash-message.txt"
else
  gh pr merge "$pr_number" --merge --delete-branch
fi
```

`--delete-branch` removes the remote branch and the local tracking branch. Clean up any lingering local branch **only if the merge happened** (`merge_ok=1`):

```bash
if [[ "${merge_ok:-0}" == "1" ]]; then
  default_branch=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')
  branch=$(gh pr view "$pr_number" --json headRefName --jq '.headRefName')
  git checkout "$default_branch" >/dev/null 2>&1 || true
  git pull --ff-only >/dev/null 2>&1 || true
  git branch -D "$branch" 2>/dev/null || true          # local
  git remote prune origin >/dev/null 2>&1 || true      # drop stale remote-tracking ref
fi
```

If `gh pr merge` fails (e.g. branch protection race, required review not yet registered, a thread re-opened), retry once after 30s. If it still fails, fall back to labeling `needs-human` and posting the error.

Return success to the caller (`start-feature`). The caller is responsible for clearing `.mco-cache/_lock`.

### Needs-human (failure)

Apply the `needs-human` label, post a summary comment using the same handover-summary block (so the human can see exactly which workers tried and where they got stuck), return failure. Caller clears the lock.

## Scripts

`scripts/wait-for-codex.sh` — the background review watcher used by step 2. Installs via `npx skills` (pr-loop is its own skill folder); runtime path `~/.agents/skills/pr-loop/scripts/wait-for-codex.sh`. Signature: `wait-for-codex.sh <pr-number> <trigger-comment-id> <round-dir>`. Exit codes: `0` findings, `3` clean, `2` timeout, `4` usage error. Keep the signature and exit-code contract stable — step 2 branches on them.

## Subagent

`agents/claude-code/pr-fixer.md`, `agents/opencode/pr-fixer.md`, `agents/codex/pr-fixer.toml`, and `agents/antigravity/pr-fixer.md` — same role, CLI-specific native formats. Registered as `pr-loop-pr-fixer` after the post-install bootstrap (`~/.agents/skills/start-feature/scripts/install-agents.sh`) runs. Keep all variants in sync.

## State / cache layout

```
.mco-cache/<pr>/
  round-0/                    # initial implementation (route-task writes this)
    worker, rationale, prompt.md, <worker>.out, <worker>.err
  round-1/
    pr.json                   # gh pr view: reviews summary, issue comments, checks, head oid
    review-comments.json      # gh api pulls/<n>/comments: the inline findings (source of truth)
    reactions.json            # gh api: reactions on the @codex trigger comment (👍 = clean)
    comments.json, blocking.json, status.json
    fix-<comment-id>.md       # one per fix subagent invocation
  round-2/ ...
  round-3/                    # re-route via route-task; same shape as round-0
    worker, rationale, prompt.md, <worker>.out, <worker>.err
  round-4/                    # only exists if we hit the cap
    summary.md
```

Cache is best-effort. If it's missing or corrupt, reconstruct from the `gh` API.
