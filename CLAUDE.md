# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A distribution kit (not an application). It ships agent **skills** + **subagents** that turn Claude Code into an orchestrator that routes implementation work to other CLIs (OpenCode, Gemini) and runs an autonomous Codex PR review loop. Distributed via `npx skills add araozmd/multi-cli-orchestrator`.

Status is `v0.1.0` — scaffold only. Every `SKILL.md`, subagent, and `scripts/invoke-worker.sh` is a placeholder that points to the design spec. Phase 1 implementation has not started. **The canonical contract is [`docs/specs/2026-04-30-multi-cli-orchestrator-design.md`](docs/specs/2026-04-30-multi-cli-orchestrator-design.md) — read it before changing skill behavior, routing rules, or merge gates.**

## Architecture (big picture)

Three skills cooperate as a pipeline; subagents give per-step context isolation; one shell script is the only seam where worker CLIs are actually invoked.

```
/start-feature  →  route-task  →  invoke-worker.sh  →  pr-loop  →  auto-merge
   (spec/PR)     (routing-judge)   (claude|opencode|gemini)  (pr-fixer per comment)
```

- `skills/start-feature/` — entry point. Brainstorms spec, generates a test plan (which doubles as the Codex review checklist), opens a draft PR with both in the description, then hands off.
- `skills/route-task/` — encodes the task-type → worker rules in **one** place so routing stays debuggable. Rules: Gemini = large-context, OpenCode = mechanical, Claude = judgment / ambiguity / post-review fixes. Calls the `routing-judge` subagent for the actual decision.
- `skills/pr-loop/` — drives the Codex review cycle: classify comments by severity (P0/P1 block; P2/nit ignored), fix via `pr-fixer` subagent on rounds 1–2, **escalate to a different worker on round 3** (recovery via worker diversity), label `needs-human` and stop on round 4. Stall detection: same P0/P1 twice in a row → skip to round 3 early.
- `skills/*/agents/{claude-code,opencode}/*.md` — subagents (Claude Code + OpenCode only; Codex/Gemini lack the abstraction). The two CLIs use different frontmatter — Claude Code uses the `name:` field as identifier; OpenCode uses the filename and requires `mode: subagent` — so each subagent ships in two versions. Keep them pure: `routing-judge` makes a decision, no side effects; `pr-fixer` fixes one comment per invocation, no looping/polling/merging. Keep both versions in sync when you change the body.
- `scripts/invoke-worker.sh` — **single chokepoint** for every worker CLI call. Today it shells out (currently echoes `TODO`). Future Phase 4: drop-in A2A client wrapper. **Keep its signature stable** (`<worker> <prompt-file>`) — that stability is what makes the A2A swap a one-file change.
- `scripts/install-agents.sh` — post-install bootstrap. The `npx skills` CLI installs skill folders verbatim but does **not** register bundled subagents with Claude Code (`~/.claude/agents/`) or OpenCode (`~/.config/opencode/agents/`). This script walks `<skills-dir>/*/agents/<cli>/*.md` and symlinks each one as `<skill>-<agent>.md` into the right dir. Idempotent. Re-run after `npx skills update` adds new subagents. Use `--unlink` to remove, `--dry-run` to preview.

## Invariants worth preserving

- **State is split**: PR description holds the contract (spec + test plan, human-visible via `gh`); `.mco-cache/<pr-number>/round-<n>/` (gitignored) holds per-iteration artifacts. Cache is best-effort — the loop must be able to reconstruct from `gh` API if it's missing.
- **Strict merge gates** (all required, no human button): CI + tests + typecheck + lint green, zero unresolved P0/P1 Codex comments, branch protection enforced on `main`. Don't add a "skip gate" path.
- **4-round cap is hard**. No infinite loops. Token/cost cap is also a hard abort with `needs-human`.
- **Codex blocking severity is P0/P1 only**. P2 and nits never gate merge.
- **No A2A, no Agent SDK driver, no GitHub Action runner in v1.** All three are explicitly tracked tech debt; don't smuggle them in. v1 runs inside an interactive Claude Code session.

## Configuration surface

Documented in README "Configuration" — `GH_TOKEN`, `MCO_MAX_ROUNDS` (default 4), `MCO_TOKEN_BUDGET_USD`, `MCO_BLOCKING_SEVERITIES` (default `P0,P1`). When implementing skills, read these env vars rather than hardcoding.

## Distribution constraint

Skills are consumed by `vercel-labs/skills` CLI, which expects the layout `skills/<name>/SKILL.md` with frontmatter (`name`, `description`). Subagents live under `skills/<name>/agents/<cli>/<agent>.md` (per-CLI subdir) so they ride along with the skill folder. Targeting flags: `-a claude-code -a opencode -g`. Subagent registration is **not** automatic — `scripts/install-agents.sh` is the second step users must run.

## Common commands

There is no build/test/lint right now — `package.json` has no scripts and no dependencies. When Phase 1 lands, the relevant commands will be the consumer-facing ones (`/start-feature "..."`, `npx skills update`) and `gh` calls inside `pr-loop`. Update this section once those exist.
