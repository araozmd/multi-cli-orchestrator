# E00-F01 — Adapt harness to this project (Builder progress)

Status: implementation complete, ready for review. (Status NOT changed — Orchestrator/Reviewer own transitions.)

## What I changed

1. **`.harness/state/tasks.json`** — `"project"` set from `"TODO-rename-me"` → `"multi-cli-orchestrator"`. No status fields touched. Re-validated with the exact command from the brief.

2. **`.harness/harness.config.yaml`** (`verification:` block) — kept the existing explanatory comments and added rationale:
   - `test_command: "bash -n skills/start-feature/scripts/invoke-worker.sh skills/start-feature/scripts/install-agents.sh"` — this is a distribution kit with no app build/test, so a bash syntax check over the two shipped runtime scripts is the meaningful "does it parse" gate. Confirmed both filenames exist via `ls skills/start-feature/scripts/` (only `install-agents.sh` and `invoke-worker.sh` are present).
   - `lint_command: ""` — **shellcheck is NOT installed** on this machine (`command -v shellcheck` returned nothing). Left empty and added a comment with the exact command to set once shellcheck is available.
   - `typecheck_command: ""` — not applicable; no typed source.

3. **`.harness/init.sh`** — I DID add a low-risk project-specific check, replacing the placeholder `echo "ℹ️ no project-specific checks configured"` line in the clearly-delimited "Project-specific checks" section (it was already designed to be edited per repo). The check probes for `skills/start-feature/scripts/` relative to both the harness parent (`..`, the normal installed case where init.sh cd's into `.harness/`) and `.` (defensive), then `fail`s if either shipped script is missing, else prints `✅ shipped worker scripts present`. If the dir isn't found it prints an info line and continues (no false failure). This cannot regress the structural/JSON gates above it.

## Verification (self-checks, all from repo root unless noted)

- `python3 -c "import json;json.load(open('state/tasks.json'))"` → exit 0 (`JSON-OK`).
- `./init.sh` → exit 0. Output now includes `✅ shipped worker scripts present`.
- `bash -n skills/start-feature/scripts/invoke-worker.sh skills/start-feature/scripts/install-agents.sh` (the configured `test_command`) → exit 0.

## Notes / follow-ups
- Install shellcheck (`brew install shellcheck`) to enable `lint_command`; the exact command is pre-written in the config comment.
- Did NOT seed any project backlog (epics/features) — out of scope per brief.
