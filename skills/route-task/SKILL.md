---
name: route-task
description: Decide which CLI worker (Claude, OpenCode, or Gemini) should implement a given task. Routes by task type — large-context to Gemini, mechanical to OpenCode, judgment to Claude. Returns the chosen worker and a short rationale; the caller invokes the worker via the orchestrator's invoke-worker.sh chokepoint.
---

# route-task

Encapsulates the task-type → worker mapping in one place so routing stays debuggable.

## Routing rules (v2 — 2026 Strategy)

| Tier | Worker | When to pick |
| :--- | :--- | :--- |
| **L5 (Critical)** | **Claude Code** | Architecture, vague specs, core logic refactors, or "impossible" bugs. |
| **L4 (Expert)** | **Codex** | High-speed implementation of complex but well-defined technical plans (GPT-5.3). |
| **L3 (Standard)** | **Gemini CLI** | Large-context: whole-repo migrations, doc generation, second-opinion review. |
| **L2 (Efficiency)** | **OpenCode** | Unit tests, boilerplate, utility functions. Uses subscription models. |
| **L1 (Mechanical)** | **Smart Worker** | Formatting, lint fixes, trivial docs. Lowest cost/highest throughput. |

## Inputs

The caller (usually `start-feature` or `pr-loop`) provides:

- `task` — path to a markdown file describing the work
- `pr_number` — the in-flight PR (used for cache path)
- `round` — `0` for initial implementation, `≥3` for escalation re-routing
- `exclude` (optional, comma-separated) — workers already tried and to skip; required when `round ≥ 3`
- `budget_status` (optional) — `normal` or `low`. If omitted, defaults to `normal` unless `MCO_LOW_BUDGET=1` is set in the environment.

## Runbook

### Step 1 — Decide the worker

Determine the `budget_status`:
```bash
if [[ "${MCO_LOW_BUDGET:-0}" == "1" ]]; then
  status="low"
else
  status="${budget_status:-normal}"
fi
```

Spawn the `route-task-routing-judge` subagent (Agent tool, `subagent_type: route-task-routing-judge`). Pass it:

- The contents of the task file
- The routing rules above (verbatim)
- The exclude list (if present)
- The `budget_status`: $status

Expect the subagent to return four fields, parseable from its message:

```
complexity: <1-5>
worker: <claude|codex|gemini|opencode|smart-worker>
rationale: <one sentence>
prompt: <the task prompt rewritten for the chosen worker>
```

If parsing fails (missing field, unknown worker, worker is in `exclude`), retry the subagent once with the explicit constraint quoted back. If it fails again, return failure to the caller.

### Step 2 — Cache the routing decision & telemetry

```bash
round_dir=".mco-cache/$pr_number/round-$round"
mkdir -p "$round_dir"
echo "$complexity" > "$round_dir/complexity"
echo "$worker" > "$round_dir/worker"
echo "$rationale" > "$round_dir/rationale"
printf '%s' "$prompt" > "$round_dir/prompt.md"
echo "$(date +%s)" > "$round_dir/start_time"

# role: implementation | fix | escalation — used by pr-loop's handover summary
if [[ "$round" == "0" ]]; then
  echo "implementation" > "$round_dir/role"
else
  echo "escalation" > "$round_dir/role"
fi
```

### Step 3 — Invoke the worker

```bash
INVOKE="${MCO_SKILL_ROOT:-$HOME/.agents/skills/start-feature}/scripts/invoke-worker.sh"
if bash "$INVOKE" "$worker" "$round_dir/prompt.md" "$round_dir"; then
  echo "success" > "$round_dir/status"
else
  echo "failure" > "$round_dir/status"
  exit 1
fi
echo "$(date +%s)" > "$round_dir/end_time"
```

### Step 4 — Update Global Metrics

After completion, append the result to `.mco-cache/metrics.json` (initialize if missing):
```json
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "pr": "$pr_number",
  "round": "$round",
  "worker": "$worker",
  "complexity": "$complexity",
  "status": "$(cat $round_dir/status)",
  "duration": $(( $(cat $round_dir/end_time) - $(cat $round_dir/start_time) ))
}
```


## Subagent

`agents/claude-code/routing-judge.md` and `agents/opencode/routing-judge.md` — same role, two CLI-specific frontmatter variants. Registered as `route-task-routing-judge` after the post-install bootstrap (`~/.agents/skills/start-feature/scripts/install-agents.sh`) runs. Keep both bodies in sync.
