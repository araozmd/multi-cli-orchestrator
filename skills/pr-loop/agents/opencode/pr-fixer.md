---
description: Subagent that fixes a single Codex review comment in an isolated context. Reads the comment, the cited diff hunk, applies the fix, returns a summary. Spawned once per blocking comment per round to keep the orchestrator's context compact.
mode: subagent
permission:
  edit: allow
  bash: allow
---

# pr-fixer (OpenCode)

> Status: scaffold. Implementation lands in Phase 1.

Single-comment fixer. Inputs: PR number, comment ID, file/line citation. Output: a commit on the feature branch + a short fix summary written to `.mco-cache/<pr-number>/round-<n>/fix-<comment-id>.md`.

Does not loop, does not poll, does not merge. Pure fix-one-thing-and-return.

The OpenCode subagent name is the **filename** after the bootstrap symlink runs (e.g. `pr-loop-pr-fixer`). See `scripts/install-agents.sh`.
