# multi-cli-orchestrator

> Cross-CLI orchestration skills for AI coding agents. Claude Code drives the design, routes implementation work to Gemini or OpenCode, and runs an autonomous Codex PR review loop that auto-merges when every gate is green.

[![Install with npx skills](https://img.shields.io/badge/install-npx%20skills-black)](https://skills.sh)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## Why this exists

Claude is excellent at architecture and judgment. It is also expensive to run as a generalist on every refactor, doc pass, and repo-wide read. This kit splits the work:

- **Claude Code** stays the orchestrator and judgment worker.
- **Gemini CLI** absorbs large-context tasks (full-repo reads, summaries, second-opinion reviews).
- **OpenCode** handles mechanical implementation (refactors, test scaffolding, parallel chunks).
- **Codex CLI** is the guardian — it reviews the PR before merge.

The result: token pressure on Claude drops, PRs get a second pair of eyes for free, and the merge gate stays strict.

## Status

`v0.1.0` — scaffold. The skills, subagents, and helper scripts are placeholders that point to [`docs/specs/2026-04-30-multi-cli-orchestrator-design.md`](docs/specs/2026-04-30-multi-cli-orchestrator-design.md). Implementation lands in Phase 1.

## Prerequisites

- macOS or Linux
- Node 18+ (for `npx skills`)
- GitHub CLI (`gh`) authenticated against the repo you want to orchestrate
- Claude Code CLI (the orchestrator)
- At least one worker CLI: `codex`, `opencode`, or `gemini`
- A repo with branch protection on `main` (the strict-merge gates assume it)

## Install

```bash
npx skills add araozmd/multi-cli-orchestrator
```

Targets a specific subset of CLIs (recommended for this kit — only Claude and OpenCode benefit from the subagents):

```bash
npx skills add araozmd/multi-cli-orchestrator -a claude-code -a opencode -g
```

Flags worth knowing:
- `-g` installs globally to `~/<agent>/skills/` (available across projects).
- Without `-g`, installs project-locally to `./<agent>/skills/`.
- Default install method symlinks to a canonical copy under `~/.agents/`, so `npx skills update` brings every project up to date in one step.

Update later:

```bash
npx skills update
```

## Configuration

After install, set a few environment variables (or use `direnv` per project):

```bash
# Required
export GH_TOKEN=$(gh auth token)            # used by pr-loop to read/post on PRs

# Optional — caps per loop run
export MCO_MAX_ROUNDS=4                     # default 4
export MCO_TOKEN_BUDGET_USD=5.00            # abort + notify if exceeded
export MCO_BLOCKING_SEVERITIES="P0,P1"      # default P0,P1
```

Make sure your project's `main` has branch protection enabled with required status checks (CI, tests, typecheck, lint). The auto-merge gate relies on it.

## How it works

```
┌──────────┐    ┌──────────────┐    ┌──────────────┐
│   You    ├───►│ Claude Code  ├───►│ route-task   │
└──────────┘    │ (orchestrator)│    │  (skill)     │
                └───────┬──────┘    └──────┬───────┘
                        │                  │
                        │           ┌──────┴───────┐
                        │           ▼              ▼
                        │      OpenCode          Gemini
                        │      (mechanical)      (large-context)
                        │           │              │
                        ▼           └──────┬───────┘
                  ┌─────────┐              │
                  │ pr-loop │◄─────────────┘
                  │ (skill) │     (commits pushed to feature branch)
                  └────┬────┘
                       │  @codex review
                       ▼
                  ┌─────────┐
                  │  Codex  │  P0/P1 → fix loop (max 4 rounds)
                  │ (guard) │  P2/nit → ignored
                  └────┬────┘
                       │  all gates green
                       ▼
                  ┌─────────┐
                  │  main   │  auto-merge
                  └─────────┘
```

### The skills

| Skill | Trigger | Job |
|---|---|---|
| [`start-feature`](skills/start-feature/SKILL.md) | User describes a feature, bug, or change | Brainstorm spec, generate test plan, create branch, open PR, hand off |
| [`route-task`](skills/route-task/SKILL.md) | Implementation task needs a worker | Pick Claude / OpenCode / Gemini by task type and return the prompt |
| [`pr-loop`](skills/pr-loop/SKILL.md) | PR is open and ready for review | Run the Codex review cycle, fix on rounds 1–2, escalate on round 3, stop on round 4, auto-merge when green |

### The subagents (Claude Code / OpenCode only)

| Subagent | Lives in | Job |
|---|---|---|
| [`routing-judge`](skills/route-task/agents/routing-judge.md) | `route-task` | Pure routing decision in an isolated context |
| [`pr-fixer`](skills/pr-loop/agents/pr-fixer.md) | `pr-loop` | Fix a single Codex comment per invocation |

### Worker invocation seam

All worker calls go through [`scripts/invoke-worker.sh`](scripts/invoke-worker.sh). Today it shells out. Future: drop-in for an A2A client wrapper. Keep the signature stable.

## How to use it

The everyday flow is one command:

```text
/start-feature "Add a logout button to the navbar"
```

Walkthrough of what happens:

1. **Brainstorm.** Claude asks clarifying questions until the spec is concrete (placement, accessibility, redirect behavior, telemetry).
2. **Test plan.** Claude writes a short test plan that doubles as the Codex review checklist.
3. **Branch + PR.** Claude creates `feature/logout-button`, opens a draft PR, and pastes the spec and test plan into the description.
4. **Routing.** `route-task` decides who implements it. For a small UI change touching one component, it picks **Claude** itself. For a sweep across all routes, it picks **OpenCode**. For a "what does the auth system look like end-to-end?" pre-step, it picks **Gemini**.
5. **Implementation.** The chosen worker pushes commits to the feature branch.
6. **Codex review.** `pr-loop` triggers `@codex review` and waits.
7. **Fix loop.** Codex flags a missing `aria-label` (P1) and an inline-style instead of using the design tokens (P1). Round 1: `pr-fixer` subagent addresses both, pushes a commit. Codex re-reviews — clean. All status checks green.
8. **Auto-merge.** Branch protection sees every gate satisfied, the PR merges to `main`, and `.mco-cache/<pr-number>/` is archived.

You watched the whole thing happen, but you didn't have to type after the first line.

If something goes sideways — Codex never approves, fix loop stalls, token budget exceeded — the PR gets a `needs-human` label, the loop stops, and you take over. The cache directory has every round's artifacts so you can see exactly what was tried.

## Phased rollout

This kit is designed to earn trust gradually. The recommended path:

1. **Phase 1 — manual supervision.** Start with one trivial PR (doc fix). Watch every step. Auto-merge off.
2. **Phase 2 — soft auto-merge.** 2–3 real PRs. Auto-merge on, but you sanity-check each merge before pulling `main`.
3. **Phase 3 — full auto-merge.** Every `/start-feature` runs unattended.
4. **Phase 4 (optional) — A2A.** Wrap a worker as an A2A agent behind `invoke-worker.sh`. The seam is designed for this swap.

Don't skip phases.

## What this kit does *not* do

- It does not replace CI, tests, lint, or branch protection. Codex review is one gate among many.
- It does not run unattended in v1. The loop runs inside an interactive Claude Code session. Migrating to the Claude Agent SDK is on the [tech debt](#tech-debt--roadmap) list.
- It does not implement the A2A protocol. Worker invocation is via CLI today; the A2A wrapper is a Phase 4 swap behind a single shell function.
- It does not assume a specific test framework, CI provider, or language. The merge gates check status check names, not their internals.

## Tech debt / roadmap

- [ ] Migrate orchestrator from interactive Claude Code to Claude Agent SDK driver (~50 LOC) so the loop runs unattended.
- [ ] GitHub Action runner for cloud-hosted execution (only when team-shared).
- [ ] A2A wrapping of workers (Phase 4).
- [ ] `--dry-run` mode for `start-feature` and `pr-loop` (no push, no merge — useful in Phase 1).
- [ ] Cost dashboard summarizing per-PR token spend across all workers.

## References

- [Design spec](docs/specs/2026-04-30-multi-cli-orchestrator-design.md) — the canonical contract for v1.
- [Vercel `skills` CLI](https://github.com/vercel-labs/skills) — distribution.
- [A2A protocol](https://a2a-protocol.org/) — deferred; Phase 4 candidate.
- [obra/superpowers](https://github.com/obra/superpowers) — distribution-pattern reference.

## License

MIT — see [LICENSE](LICENSE).
