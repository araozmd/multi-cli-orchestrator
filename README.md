# multi-cli-orchestrator

> Cross-CLI orchestration skills for AI coding agents. Claude Code drives the design, routes implementation work to Gemini or OpenCode, and runs an autonomous Codex PR review loop that auto-merges when every gate is green.

[![Install with npx skills](https://img.shields.io/badge/install-npx%20skills-black)](https://skills.sh)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## Why this exists

Claude is excellent at architecture and judgment. It is also expensive to run as a generalist on every refactor, doc pass, and repo-wide read. This kit splits the work:

- **Claude Code** stays the orchestrator and judgment worker.
- **OpenCode** handles mechanical implementation (default for technical work: refactors, test scaffolding, parallel chunks, feature code).
- **Gemini CLI** absorbs large-context tasks (full-repo reads, summaries, second-opinion reviews).
- **Codex CLI** is the guardian — it reviews the PR before merge.

The result: token pressure on Claude drops, PRs get a second pair of eyes for free, and the merge gate stays strict.

## Status

`v0.2.0` — Auto-merge enabled. Core skills and subagents implemented. When all gates are green, `pr-loop` auto-merges via `gh pr merge`. Squash-merge supported with Codex journey summaries (`MCO_MERGE_STRATEGY=squash`).

## Prerequisites

- macOS or Linux
- Node 18+ (for `npx skills`)
- GitHub CLI (`gh`) authenticated against the repo you want to orchestrate
- Claude Code CLI (the orchestrator)
- At least one worker CLI: `codex` (Plus subscription), `opencode`, or `gemini`
- A repo with branch protection on `main` (the strict-merge gates assume it)

## Install

```bash
npx skills add araozmd/multi-cli-orchestrator
```

Targets the four code agents this kit ships native subagent definitions for:

```bash
npx skills add araozmd/multi-cli-orchestrator -g -s '*' -a claude-code opencode codex antigravity
```

Flags worth knowing:
- `-g` installs globally to `~/<agent>/skills/` (available across projects).
- Without `-g`, installs project-locally to `./<agent>/skills/`.
- Default install method symlinks to a canonical copy under `~/.agents/`, so `npx skills update` brings every project up to date in one step.

Update later:

```bash
npx skills update
```

### Register the bundled subagents

The `npx skills` CLI installs each skill folder as-is, but it does **not** relocate the bundled subagents (`pr-fixer`, `routing-judge`) into the per-CLI agents directory where each tool actually looks. Run the bootstrap once to symlink them:

```bash
# After `npx skills add ... -g`
bash ~/.agents/skills/start-feature/scripts/install-agents.sh --global

# Or, for a project-scoped install
bash ~/.agents/skills/start-feature/scripts/install-agents.sh --project
```

The bootstrap script ships inside the `start-feature` skill (under `skills/start-feature/scripts/`) so it gets copied to disk by `npx skills` itself — top-level sibling files would not. Same goes for the worker harness (`invoke-worker.sh`).

What the script does:

- Walks every supported `<skills-dir>/*/agents/<cli>/<agent>.<ext>` it finds. It scans the universal `~/.agents/skills` store plus CLI-specific skill directories.
- Symlinks each one into the matching CLI's agents directory under a namespaced filename (`<skill>-<agent>.<ext>`, e.g. `pr-loop-pr-fixer.md` or `pr-loop-pr-fixer.toml`) so multiple skills can ship a `pr-fixer` without collision.
- Uses native formats and destinations: Claude Code Markdown in `~/.claude/agents`, OpenCode Markdown in `~/.config/opencode/agents`, Codex TOML in `~/.codex/agents`, and Antigravity Markdown in `~/.gemini/config/agents`.
- Idempotent — re-run after every `npx skills update` that adds new subagents. Use `--unlink` to remove them, `--dry-run` to preview.

If you only have one CLI installed, the script silently skips missing source directories for the others.

## Configuration

After install, set a few environment variables (or use `direnv` per project):

```bash
# Required
export GH_TOKEN=$(gh auth token)            # used by pr-loop to read/post on PRs

# Optional — caps per loop run
export MCO_MAX_ROUNDS=4                     # default 4
export MCO_TOKEN_BUDGET_USD=5.00            # abort + notify if exceeded
export MCO_BLOCKING_SEVERITIES="P0,P1"      # default P0,P1
export MCO_LOW_BUDGET=1                     # aggressively route to cheap workers (Kimi, Gemini)
export MCO_MERGE_STRATEGY="merge"           # or "squash" for Codex-generated commit summaries
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
| [`route-task`](skills/route-task/SKILL.md) | Implementation task needs a worker | Pick Claude / OpenCode / Gemini / Smart Worker by task type and session budget |
| [`pr-loop`](skills/pr-loop/SKILL.md) | PR is open and ready for review | Run the Codex review cycle, fix on rounds 1–2, escalate on round 3, stop on round 4, auto-merge when green |

### The subagents

| Subagent | Lives in | Job |
|---|---|---|
| [`routing-judge`](skills/route-task/agents/) | `route-task` | Pure routing decision in an isolated context. Variants: [Claude Code](skills/route-task/agents/claude-code/routing-judge.md), [OpenCode](skills/route-task/agents/opencode/routing-judge.md), [Codex](skills/route-task/agents/codex/routing-judge.toml), [Antigravity](skills/route-task/agents/antigravity/routing-judge.md) |
| [`pr-fixer`](skills/pr-loop/agents/) | `pr-loop` | Fix a single Codex comment per invocation. Variants: [Claude Code](skills/pr-loop/agents/claude-code/pr-fixer.md), [OpenCode](skills/pr-loop/agents/opencode/pr-fixer.md), [Codex](skills/pr-loop/agents/codex/pr-fixer.toml), [Antigravity](skills/pr-loop/agents/antigravity/pr-fixer.md) |

Each CLI needs its native shape: Claude Code uses Markdown with `name:`, OpenCode uses Markdown with `mode: subagent`, Codex uses standalone TOML custom agents, and Antigravity uses Markdown agent personas. The bootstrap script picks the right one per CLI.

### Worker invocation seam

All worker calls go through [`skills/start-feature/scripts/invoke-worker.sh`](skills/start-feature/scripts/invoke-worker.sh). Today it shells out to `claude` / `codex` / `opencode` / `gemini` / `agy` with the right headless-approval flags. Future: drop-in for an A2A client wrapper. Keep the signature stable. After `npx skills update` it lives at `~/.agents/skills/start-feature/scripts/invoke-worker.sh`; the orchestrator skills resolve it via `${MCO_SKILL_ROOT:-$HOME/.agents/skills/start-feature}/scripts/invoke-worker.sh`.

## Optional: drive it from the SDD harness

This kit pairs with [`harness-sdd`](https://github.com/araozmd/harness-sdd) — a portable
Spec-Driven-Development harness (Orchestrator → Architect → Builder → Reviewer). The two
are independent: the harness runs fine on a single CLI, and this kit runs fine on its own
via `/start-feature`. When both are present, the harness can use this kit as its
**implementation engine** — the dependency points *down* (the harness never learns this
kit exists; this kit plugs into the harness's one extension point).

The seam is the harness's `execution.builder` backend. Opt in:

```yaml
# .harness/harness.config.yaml
execution:
  builder:
    backend: delegate
    delegate_cmd: "bash skills/start-feature/scripts/harness-delegate.sh"
```

Now the harness Builder phase doesn't write code — it calls
[`harness-delegate.sh`](skills/start-feature/scripts/harness-delegate.sh)
`<feature-id> <abs-spec-path>`, which:

1. **assembles** the feature's 4-file spec (`.spec`/`.plan`/`.tasks`/`.tests`) into one
   prompt and runs the chosen worker via `invoke-worker.sh` (round-0 implementation);
2. **commits** the result on a branch and opens a **draft** PR whose body carries the
   spec + test plan (the Codex review checklist), then emits a
   `MCO_DELEGATE_RESULT … pr=<n>` handoff line and stops.

The draft state is deliberate — it's what gates auto-merge behind the **local review**.
The full delegated flow, end to end:

```
harness: Architect → (human gate) → Builder[delegate]
                                        │
                         harness-delegate.sh  (worker → commit → draft PR)
                                        │
            harness Reviewer (LOCAL, pre-merge gate)  ──reject──► back to Builder
                                        │ approve
                              pr-loop skill (gh pr ready → @codex review)
                                        │ all gates green
                                   auto-merge → feature `done`
```

Both reviewers run, in order: the **local harness Reviewer** verifies spec-conformance on
the branch *before* the PR is readied, then **Codex** gates on the PR. Auto-merge cannot
race the local review because the PR stays draft until local approval.

Worker selection defaults to `claude`; override per-run with `MCO_WORKER`, or let
`route-task` choose in the full pipeline. `MCO_DRY_RUN=1` exercises the whole bridge
(prompt assembly + the exact CLI/git/`gh` commands) without spending tokens or opening a
PR.

> **Status:** the bridge implements STAGE 1 (spec → worker) and STAGE 2 (commit → draft
> PR). The local-Reviewer → `pr-loop` → merge handoff is agent-driven (the harness
> Orchestrator routes it); the bridge hands back the PR number for that next step.

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

1. **Phase 1 — supervised auto-merge.** Start with one trivial PR (doc fix). Watch every step. Auto-merge is on but you sanity-check each merge before pulling `main`.
2. **Phase 2 — full auto-merge.** Every `/start-feature` runs unattended.
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
