# Multi-CLI Orchestrator — GEMINI.md

This project is a distribution kit for AI agent skills and subagents, designed to orchestrate multiple LLM-powered CLIs. It enables Claude Code to act as a design-focused orchestrator that routes implementation tasks to specialized workers (Gemini, OpenCode) and automates the PR review cycle via Codex.

## Core Architecture

The orchestrator operates as a pipeline across three main skills:

1.  **`start-feature`**: The entry point. It brainstorms a spec with the user, generates a test plan (Codex checklist), and opens a draft PR.
2.  **`route-task`**: Decides which CLI worker should handle a task based on its type:
    *   **Gemini CLI**: Large-context (full-repo reads, summaries, doc generation).
    *   **OpenCode**: Mechanical implementation (default for technical work: refactors, scaffolding, parallel tasks). Uses `openai/gpt-5.3-codex` by default.
    *   **Smart Worker**: High-capability open-source models (Kimi k2, DeepSeek v3.1) via OpenRouter.
    *   **Claude Code (self)**: Judgment, architecture, and post-review fixes.
3.  **`pr-loop`**: Drives an autonomous Codex PR review cycle. It classifies comments by severity (P0/P1 block; P2/nits ignore), applies fixes, and escalates to different workers if needed (Round 3).

### Key Components & Scripts

*   **`invoke-worker.sh`**: The single chokepoint for all worker CLI calls (`claude`, `opencode`, `gemini`, `smart-worker`). Includes automatic model fallback for the `smart-worker`.
*   **`install-agents.sh`**: Post-install bootstrap that symlinks bundled subagents into CLI-specific agent directories.
*   **`.mco-cache/`**: Local cache for in-flight PR artifacts and the single-feature lock file.

## Operational Invariants

*   **Budget-Aware Routing**: When `MCO_LOW_BUDGET=1` (or `budget_status=low`) is detected, the orchestrator aggressively routes implementation tasks to the `smart-worker` or `gemini` to preserve Claude's session limit.
*   **Strict Merge Gates**: Auto-merge (or "ready to merge" signal) requires:
    *   All CI/tests/lint/typecheck status checks are green.
    *   Zero unresolved P0 or P1 Codex comments.
    *   Branch protection enforced on `main`.
*   **Hard Loop Cap**: The `pr-loop` is hard-capped at 4 rounds to prevent infinite loops.
*   **Single-Feature Lock**: Only one feature can be in flight at a time (controlled by `.mco-cache/_lock`).
*   **Blocking Severities**: Only P0 and P1 Codex tags block a merge. P2 and nits are informational.
*   **Worker Escalation**: If a fix fails in Round 1 or 2, Round 3 escalates the task to a *different* worker model for a fresh perspective.

## Command Reference

### Consumer Commands
*   `/start-feature "<description>"`: Initiates the full orchestration pipeline.
*   `npx skills update`: Updates the skills from the repository.
*   `bash ~/.agents/skills/start-feature/scripts/install-agents.sh`: (Post-install/update) Symlinks subagents into CLI directories.

### Troubleshooting & Diagnostics
*   `rm .mco-cache/_lock`: Force-clears the single-feature lock if a session crashes.
*   `MCO_DRY_RUN=1 bash ~/.agents/skills/start-feature/scripts/invoke-worker.sh <worker> <prompt-file>`: Tests the worker harness without spending tokens.

## Configuration

The following environment variables control orchestrator behavior:

| Variable | Default | Purpose |
| :--- | :--- | :--- |
| `GH_TOKEN` | (Required) | GitHub CLI token for PR interaction and Codex triggers. |
| `MCO_MAX_ROUNDS` | `4` | Maximum iterations of the `pr-loop`. |
| `MCO_TOKEN_BUDGET_USD` | (Optional) | Hard abort if the total token spend exceeds this USD value. |
| `MCO_BLOCKING_SEVERITIES` | `P0,P1` | Comma-separated list of Codex tags that gate the merge. |
| `MCO_MERGE_STRATEGY` | `merge` | If `squash`, Codex summarizes the journey into a commit message. |
| `MCO_DRY_RUN` | `0` | If `1`, disables actual PR creation, commits, and Codex pings. |

## Project Structure & Distribution

This repo is structured for distribution via `npx skills`.
*   `skills/`: Contains the functional skill folders (`start-feature`, `route-task`, `pr-loop`).
*   `skills/<skill>/agents/<cli>/`: Subagent variants for Claude Code and OpenCode.
*   `skills/start-feature/scripts/`: Harness scripts distributed alongside the skills.
*   `docs/specs/`: Canonical design contracts for the orchestration logic.
