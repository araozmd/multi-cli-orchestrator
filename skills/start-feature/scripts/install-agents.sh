#!/usr/bin/env bash
# install-agents.sh — register bundled subagents with supported code agents.
#
# The `npx skills` CLI installs each skill's full folder tree into the agent's
# skills directory, but it does NOT relocate the bundled subagent files into
# the per-CLI agents directory where code agents look for native
# subagents. This script bridges that gap by symlinking
#   <skills-dir>/<skill>/agents/<cli>/<agent>.<ext>
# into the matching CLI's agents directory under a namespaced filename
# (`<skill>-<agent>.<ext>`) to avoid collisions across skills.
#
# Run once after `npx skills add ...` and again after any update that adds new
# subagents. Idempotent. After `npx skills update`, this script is at:
#   ~/.agents/skills/start-feature/scripts/install-agents.sh
#
# Usage (use the install path above; `BOOT` aliases it for the examples):
#   BOOT=~/.agents/skills/start-feature/scripts/install-agents.sh
#   bash "$BOOT"               # link both global + project scopes
#   bash "$BOOT" --global      # global only
#   bash "$BOOT" --project     # project only
#   bash "$BOOT" --unlink      # remove links pointing at our skills
#   bash "$BOOT" --dry-run     # print what would happen, change nothing
#
# Discovers any skill (not just the ones in this repo) that follows the
# `agents/<cli>/<agent>.<ext>` convention.

set -euo pipefail

MODE="link"
SCOPE="both"
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --global)   SCOPE="global" ;;
    --project)  SCOPE="project" ;;
    --both)     SCOPE="both" ;;
    --unlink)   MODE="unlink" ;;
    --dry-run)  DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '%s\n' "$*"; }
do_run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    log "DRY: $*"
  else
    eval "$*"
  fi
}

# realpath shim (macOS lacks GNU `realpath` by default; coreutils' `greadlink`
# isn't guaranteed either). Resolve via Python.
resolve_path() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }

# Specs: <skills-dir>|<agents-dir>|<cli>|<extension>
# Skills CLI install paths come from vercel-labs/skills:
#   Claude Code: ./.claude/skills (project), ~/.claude/skills (global)
#   OpenCode:    ./.agents/skills (project), ~/.config/opencode/skills (global)
#   Universal:   ./.agents/skills (project), ~/.agents/skills (global)
#   Antigravity: ~/.gemini/config/skills (global), ./.agents/skills (project)
# Native subagent dirs come from each CLI's docs:
#   Claude Code: ./.claude/agents, ~/.claude/agents
#   OpenCode:    ./.opencode/agents, ~/.config/opencode/agents
#   Codex:       ./.codex/agents, ~/.codex/agents
#   Antigravity: ./.agents/agents, ~/.gemini/config/agents
declare -a SPECS=()
if [[ "$SCOPE" == "global" || "$SCOPE" == "both" ]]; then
  SPECS+=("$HOME/.claude/skills|$HOME/.claude/agents|claude-code|md")
  SPECS+=("$HOME/.agents/skills|$HOME/.claude/agents|claude-code|md")
  SPECS+=("$HOME/.config/opencode/skills|$HOME/.config/opencode/agents|opencode|md")
  SPECS+=("$HOME/.agents/skills|$HOME/.config/opencode/agents|opencode|md")
  SPECS+=("$HOME/.codex/skills|$HOME/.codex/agents|codex|toml")
  SPECS+=("$HOME/.agents/skills|$HOME/.codex/agents|codex|toml")
  SPECS+=("$HOME/.gemini/config/skills|$HOME/.gemini/config/agents|antigravity|md")
  SPECS+=("$HOME/.agents/skills|$HOME/.gemini/config/agents|antigravity|md")
fi
if [[ "$SCOPE" == "project" || "$SCOPE" == "both" ]]; then
  SPECS+=("$PWD/.claude/skills|$PWD/.claude/agents|claude-code|md")
  SPECS+=("$PWD/.agents/skills|$PWD/.claude/agents|claude-code|md")
  SPECS+=("$PWD/.agents/skills|$PWD/.opencode/agents|opencode|md")
  SPECS+=("$PWD/.codex/skills|$PWD/.codex/agents|codex|toml")
  SPECS+=("$PWD/.agents/skills|$PWD/.codex/agents|codex|toml")
  SPECS+=("$PWD/.agents/skills|$PWD/.agents/agents|antigravity|md")
fi

link_one() {
  local src="$1" dst="$2"
  if [[ -L "$dst" ]]; then
    local current; current="$(resolve_path "$dst")"
    local target;  target="$(resolve_path "$src")"
    if [[ "$current" == "$target" ]]; then
      log "= $dst (already linked)"
      return 0
    fi
    log "! $dst points elsewhere ($current); skipping. Run with --unlink first or remove manually."
    return 0
  fi
  if [[ -e "$dst" ]]; then
    log "! $dst exists and is not a symlink; skipping (won't clobber)."
    return 0
  fi
  do_run "ln -s '$src' '$dst'"
  log "+ $dst -> $src"
}

unlink_one() {
  local dst="$1" cli="$2" ext="$3"
  [[ -L "$dst" ]] || return 0
  # Compare against the resolved target so we recognize links even after the
  # skills CLI redirects through its canonical ~/.agents/skills/ store.
  local target; target="$(resolve_path "$dst")"
  if [[ "$target" == */agents/"$cli"/*."$ext" ]]; then
    do_run "rm '$dst'"
    log "- $dst"
  fi
}

process_spec() {
  local skills_dir="$1" agents_dir="$2" cli="$3" ext="$4"
  [[ -d "$skills_dir" ]] || return 0

  if [[ "$MODE" == "link" ]]; then
    do_run "mkdir -p '$agents_dir'"
  fi

  # Find every <skills_dir>/<skill>/agents/<cli>/<agent>.<ext>
  shopt -s nullglob
  local skill_path skill agent_path agent base dst
  for skill_path in "$skills_dir"/*; do
    [[ -d "$skill_path" ]] || continue
    skill="$(basename "$skill_path")"
    [[ -d "$skill_path/agents/$cli" ]] || continue
    for agent_path in "$skill_path/agents/$cli"/*."$ext"; do
      agent="$(basename "$agent_path" ".$ext")"
      base="${skill}-${agent}.${ext}"
      dst="$agents_dir/$base"
      if [[ "$MODE" == "link" ]]; then
        link_one "$agent_path" "$dst"
      else
        unlink_one "$dst" "$cli" "$ext"
      fi
    done
  done
  shopt -u nullglob
}

for spec in "${SPECS[@]}"; do
  IFS='|' read -r skills_dir agents_dir cli ext <<< "$spec"
  log ""
  log "[$cli] $skills_dir -> $agents_dir"
  process_spec "$skills_dir" "$agents_dir" "$cli" "$ext"
done

log ""
log "done."
