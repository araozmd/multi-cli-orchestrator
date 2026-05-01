---
name: start-feature
description: Entry point for the multi-CLI orchestration workflow. Use when the user wants to build a new feature, fix a bug, or make a non-trivial change. Brainstorms the spec, generates a test plan, opens a PR, hands off to the routing skill, and triggers the PR review loop.
---

# start-feature

> Status: scaffold. Implementation lands in Phase 1 per `docs/specs/2026-04-30-multi-cli-orchestrator-design.md`.

The `/start-feature` command is the user-facing entry point. It owns the lifecycle from "I want to build X" through "PR is merged."

## When to use

Trigger when the user describes a feature, bug, or change that warrants a PR. Skip for read-only questions, exploratory chats, or trivial in-place edits.

## Workflow (high level)

1. Brainstorm the spec with the user (delegates to a brainstorming flow).
2. Generate a test plan that doubles as the Codex review checklist.
3. Create a feature branch and an empty PR with the spec + test plan in the description.
4. Hand the implementation task to `route-task` to pick the right worker CLI.
5. After the worker pushes its commits, hand off to `pr-loop` for the Codex review cycle.

See the design spec for the full contract and decision log.
