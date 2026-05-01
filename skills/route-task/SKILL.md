---
name: route-task
description: Decide which CLI worker (Claude, OpenCode, or Gemini) should implement a given task. Routes by task type — large-context to Gemini, mechanical to OpenCode, judgment to Claude. Returns the chosen worker and a short rationale; the caller invokes the worker via scripts/invoke-worker.sh.
---

# route-task

> Status: scaffold. Implementation lands in Phase 1 per `docs/specs/2026-04-30-multi-cli-orchestrator-design.md`.

Encapsulates the task-type → worker mapping so routing is debuggable and changeable in one place.

## Routing rules (v1)

- **Gemini CLI** — large-context tasks: read whole repo, summarize, doc generation, second-opinion review.
- **OpenCode** — mechanical implementation: refactors, test scaffolding, parallel subtasks.
- **Claude Code (self)** — architecture, ambiguous tasks, post-review fixes, anything where judgment beats throughput.

## Subagent

`agents/routing-judge.md` — runs the routing decision in an isolated context so the orchestrator's main context stays compact.

## Output

```
worker: <claude|opencode|gemini>
rationale: <one sentence>
prompt: <the task prompt to pass to the worker>
```

The caller invokes the worker via `scripts/invoke-worker.sh <worker> "<prompt>"`.
