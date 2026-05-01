# Multi-CLI Orchestrator — Design Spec

- **Date:** 2026-04-30
- **Author:** Mauricio Araoz (with Claude Code, second opinions from ChatGPT and Gemini)
- **Status:** Approved, pending implementation plan

## Goal

Reduce token pressure on Claude Code by routing implementation work to specialized CLI workers (Gemini for large-context, OpenCode for mechanical tasks), and close the loop with an autonomous Codex PR review cycle that auto-merges when all gates are green. The orchestrator is reusable across projects and distributed via `npx skills`.

## Non-goals

- Replacing Claude Code as the design/judgment surface — Claude stays in the loop for brainstorming, planning, ambiguous tasks, and post-review fixes.
- Building an A2A protocol stack today. Worker boundaries are designed so an A2A wrapper is a future drop-in, not a Phase 1 commitment.
- Building a programmatic unattended runner (Claude Agent SDK / GitHub Action). v1 runs inside an interactive Claude Code session; unattended runtime is tracked as tech debt.
- Replacing CI, tests, lint, or branch protection. Codex review is one gate among many, not a substitute for the rest.

## Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| A2A vs. pragmatic | **Pragmatic, A2A-curious** | Claude Code, Codex CLI, and Gemini CLI don't natively expose A2A endpoints. Community wrappers are alpha. CLI + MCP + GitHub gets to a working loop in days; A2A wrapping costs 1–2 weeks for capabilities a 3-worker setup doesn't yet need. Worker invocations go through a single `invoke-worker.sh` chokepoint so swapping in A2A later is a one-file change. |
| Merge gates | **Strict auto-merge** | All of: CI green, tests green, typecheck green, lint green, zero unresolved P0/P1 Codex comments, branch protection enforced. No human-button merge. Strict gates are the safety net, not a human checkpoint. |
| Worker routing | **Task-typed (encoded rules)** | Gemini → large-context; OpenCode → mechanical; Claude → judgment / ambiguity / post-review fixes. Rules live in the `route-task` skill so they are debuggable and tunable in one place. |
| Loop failure mode | **Escalation ladder, 4 rounds max** | Rounds 1–2: Claude fixes via `pr-fixer` subagent. Round 3: route the failing fix to a different worker (different model, different perspective) — uses the multi-CLI setup as a recovery mechanism. Round 4: label `needs-human`, stop, ping the user. Stall detection: if the same P0/P1 comment reappears two rounds in a row, skip ahead to round 3. |
| Codex blocking severity | **P0 + P1 only** | P2 and nits do not gate merge. Style preferences must not loop forever. |
| Orchestrator runtime | **Interactive Claude Code (v1)** | Lowest friction for v1. Tracked as tech debt: migrate to Claude Agent SDK driver once the loop is proven on 2–3 PRs, GitHub Action only when team-shared. |
| State / artifacts | **PR description + gitignored cache** | PR description holds plan + test plan (the contract, visible to humans, discoverable via `gh`). `.mco-cache/<pr-number>/` (gitignored) holds per-iteration artifacts: Codex comment dumps, fix summaries, last-known-good diffs. |
| Subagents | **Yes (Claude Code + OpenCode only)** | `pr-fixer` and `routing-judge` give context isolation per iteration. Subagents only translate to Claude Code and OpenCode; Codex CLI and Gemini CLI lack the abstraction. Worker CLIs are invoked as plain CLIs, not subagents. The two CLIs use different frontmatter (Claude Code: `name:` field as identifier; OpenCode: filename as identifier + `mode: subagent` required), so each subagent ships in two versions under `agents/claude-code/` and `agents/opencode/`. |
| Distribution | **`npx skills` + post-install bootstrap** | `npx skills add araozmd/multi-cli-orchestrator` installs the skill folders, but the skills CLI does not relocate bundled subagents into each CLI's native agents dir (`~/.claude/agents/`, `~/.config/opencode/agents/`). A one-shot `scripts/install-agents.sh` symlinks them, namespaced as `<skill>-<agent>.md`. Idempotent; re-runnable after updates. |

## Architecture

### Roles

```
You ─────────────────► Claude Code (orchestrator + judgment worker)
                            │
              ┌─────────────┼──────────────┐
              ▼             ▼              ▼
         OpenCode        Gemini         Codex
         (mechanical)    (context)      (guardian)
              │             │              │
              └─────────────┴──────────────┘
                            │
                            ▼
                       GitHub PR
                       (state machine)
```

- **Claude Code** — orchestrator. Owns brainstorming, planning, routing decisions, post-review fixes, final acceptance. Uses subagents (`routing-judge`, `pr-fixer`) for context isolation.
- **OpenCode** — mechanical worker. Refactors, test scaffolding, parallel implementation chunks.
- **Gemini CLI** — large-context worker. Repo-wide reads, summarization, doc generation, second-opinion review.
- **Codex CLI** — guardian. PR review via `@codex review` (or auto-review). Severity-tagged comments (P0/P1/P2/nit).
- **GitHub** — the state machine. PRs, reviews, status checks, labels, branch protection.

### Components

| Component | Path | Purpose |
|---|---|---|
| `start-feature` skill | `skills/start-feature/SKILL.md` | Entry point. Brainstorm spec, generate test plan, open PR, hand off. |
| `route-task` skill | `skills/route-task/SKILL.md` | Decide which worker handles a task; encode the routing rules. |
| `routing-judge` subagent | `skills/route-task/agents/{claude-code,opencode}/routing-judge.md` | Pure decision agent for routing; returns `{worker, rationale, prompt}`. Two CLI-specific frontmatter variants. |
| `pr-loop` skill | `skills/pr-loop/SKILL.md` | Drive the Codex review cycle and auto-merge. |
| `pr-fixer` subagent | `skills/pr-loop/agents/{claude-code,opencode}/pr-fixer.md` | Fix one Codex comment per invocation in isolated context. Two CLI-specific frontmatter variants. |
| `invoke-worker.sh` | `scripts/invoke-worker.sh` | Single chokepoint for worker CLI invocation. Future A2A swap point. |
| `install-agents.sh` | `scripts/install-agents.sh` | Post-install bootstrap. Symlinks bundled subagents into each CLI's native agents dir under a `<skill>-<agent>.md` namespace. |

### Data flow per feature

```
1. User invokes /start-feature "<description>"
2. start-feature: brainstorm with user → spec
                  generate test plan (= Codex review checklist)
                  create feature branch
                  open PR (spec + test plan in description)
3. start-feature → route-task: pick worker for implementation
4. route-task → routing-judge subagent: returns {worker, prompt}
5. orchestrator → invoke-worker.sh <worker> <prompt-file>
                   worker commits implementation on feature branch
                   orchestrator pushes
6. start-feature → pr-loop: drive review cycle
7. pr-loop:
   - trigger Codex review (@codex review)
   - poll gh pr view for review completion
   - parse comments, classify severity
   - if blocking comments exist:
       round 1–2: spawn pr-fixer per comment, push fix commits
       round 3: route to different worker via invoke-worker.sh
       round 4: label needs-human, stop
   - stall detection: same P0/P1 twice → skip to round 3
   - cache iteration artifacts to .mco-cache/<pr-number>/round-<n>/
8. when all merge gates green:
   - auto-merge to main
   - move .mco-cache/<pr-number>/ → .mco-cache/_archive/<pr-number>/
```

### Merge gates (all required)

- CI green
- Tests green
- Typecheck green
- Lint green
- Zero unresolved P0 or P1 Codex comments
- Branch protection enforced on `main`

### Failure modes

- **4-round cap.** After round 4, stop, label `needs-human`, comment with iteration history. No infinite loops.
- **Stall detection.** Same P0/P1 comment surfaces in two consecutive rounds → skip to round 3 (different worker) early.
- **Token / cost cap per loop.** Configurable (e.g., max $X or N tokens). Abort with `needs-human` label and a notice if exceeded.
- **CI failure.** Treated as blocking. Same fix flow as Codex P0.
- **Worker invocation failure** (CLI exit non-zero). Retry once; if it fails again, label `needs-human`.
- **Cache corruption / missing artifacts.** Loop reconstructs from `gh` API; cache is best-effort, not authoritative.

## Phased rollout

| Phase | Scope | Exit criteria |
|---|---|---|
| **Phase 1 — manual supervision** | One trivial PR (doc fix or simple refactor). User watches every step. No auto-merge. | One PR completes the full loop without intervention. |
| **Phase 2 — soft auto-merge** | 2–3 real feature PRs. Auto-merge enabled, but user reviews each merge before pulling main. | 3 consecutive PRs merge cleanly. |
| **Phase 3 — full auto-merge** | All PRs from `/start-feature` go through the loop unattended. | Stable. |
| **Phase 4 (optional) — A2A wrapping** | Wrap one worker (start with OpenCode) as an A2A agent behind `invoke-worker.sh`. Validate the seam. | Workflow unchanged after the swap. |

## Distribution

- Public GitHub repo `araozmd/multi-cli-orchestrator`.
- Installable via `npx skills add araozmd/multi-cli-orchestrator` (vercel-labs/skills CLI).
- Targets all 50+ agents the `skills` CLI supports for the skill files themselves. Subagents are bundled inside skill folders, but the skills CLI does not auto-register them with Claude Code or OpenCode; users run `scripts/install-agents.sh` once after install (and after any update that ships new subagents) to symlink them into each CLI's native agents directory. The bootstrap is namespaced (`<skill>-<agent>.md`) so multiple skills can share an agent name without colliding.

## Tech debt / deferred

- Migrate orchestrator from interactive Claude Code to Claude Agent SDK driver (~50 LOC) so the loop can run unattended.
- GitHub Action runner for fully cloud-hosted execution (only when team-shared).
- A2A wrapping of workers (Phase 4, optional).
- LangGraph / CrewAI runtime (Gemini's suggestion; YAGNI for current scale).
- Issue-driven state model (only if existing workflows already track work in issues).

## Open questions

- Exact Codex severity tag format. The design assumes P0/P1/P2/nit; verify against current Codex output and adapt the parser if labels differ.
- Cost cap value and currency unit. To be set per project in a config file the `pr-loop` skill reads.
- Do we need a `--dry-run` mode for Phase 1 that runs the full flow without pushing or merging? Likely yes; flag during implementation planning.

## References

- Vercel `skills` CLI — https://github.com/vercel-labs/skills
- A2A protocol spec — https://a2a-protocol.org/ (deferred; Phase 4 candidate)
- ChatGPT review of this design — https://chatgpt.com/share/69f416fd-1040-83e8-bb08-984b9227cb2f
- Gemini review of this design — https://gemini.google.com/share/07802d9b52d3
- obra/superpowers (distribution-pattern reference) — https://github.com/obra/superpowers
