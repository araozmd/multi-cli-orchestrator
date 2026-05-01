#!/usr/bin/env bash
# install-agents.sh — register bundled subagents with Claude Code and OpenCode.
#
# The `npx skills` CLI installs each skill's full folder tree into the agent's
# skills directory, but it does NOT relocate the bundled subagent files into
# the per-CLI agents directory where Claude Code or OpenCode look for native
# subagents. This script bridges that gap by symlinking
#   <skills-dir>/<skill>/agents/{claude-code,opencode}/<agent>.md
# into the matching CLI's agents directory under a namespaced filename
# (`<skill>-<agent>.md`) to avoid collisions across skills.
#
# Run once after `npx skills add ...` and again after any update that adds new
# subagents. Idempotent.
#
# Usage:
#   scripts/install-agents.sh                # link both global + project scopes
#   scripts/install-agents.sh --global       # global only
#   scripts/install-agents.sh --project      # project only
#   scripts/install-agents.sh --unlink       # remove links pointing at our skills
#   scripts/install-agents.sh --dry-run      # print what would happen, change nothing
#
# Discovers any skill (not just the ones in this repo) that follows the
# `agents/<cli>/<agent>.md` convention.

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
    eval "$@"
  fi
}

# realpath shim (macOS lacks GNU `realpath` by default; coreutils' `greadlink`
# isn't guaranteed either). Resolve via Python.
resolve_path() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }

# Pairs: <skills-dir>|<claude-agents-dir>|<opencode-agents-dir>
# Skills CLI install paths come from vercel-labs/skills:
#   Claude Code: ./.claude/skills (project), ~/.claude/skills (global)
#   OpenCode:    ./.agents/skills (project), ~/.config/opencode/skills (global)
# Native subagent dirs come from each CLI's docs:
#   Claude Code: ./.claude/agents, ~/.claude/agents
#   OpenCode:    ./.opencode/agents, ~/.config/opencode/agents
declare -a PAIRS=()
if [[ "$SCOPE" == "global" || "$SCOPE" == "both" ]]; then
  PAIRS+=("$HOME/.claude/skills|$HOME/.claude/agents|claude-code")
  PAIRS+=("$HOME/.config/opencode/skills|$HOME/.config/opencode/agents|opencode")
fi
if [[ "$SCOPE" == "project" || "$SCOPE" == "both" ]]; then
  PAIRS+=("$PWD/.claude/skills|$PWD/.claude/agents|claude-code")
  PAIRS+=("$PWD/.agents/skills|$PWD/.opencode/agents|opencode")
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
  local dst="$1" cli="$2"
  [[ -L "$dst" ]] || return 0
  # Compare against the resolved target so we recognize links even after the
  # skills CLI redirects through its canonical ~/.agents/skills/ store.
  local target; target="$(resolve_path "$dst")"
  if [[ "$target" == */agents/"$cli"/*.md ]]; then
    do_run "rm '$dst'"
    log "- $dst"
  fi
}

process_pair() {
  local skills_dir="$1" agents_dir="$2" cli="$3"
  [[ -d "$skills_dir" ]] || return 0

  if [[ "$MODE" == "link" ]]; then
    do_run "mkdir -p '$agents_dir'"
  fi

  # Find every <skills_dir>/<skill>/agents/<cli>/<agent>.md
  shopt -s nullglob
  local skill_path skill agent_path agent base dst
  for skill_path in "$skills_dir"/*; do
    [[ -d "$skill_path" ]] || continue
    skill="$(basename "$skill_path")"
    [[ -d "$skill_path/agents/$cli" ]] || continue
    for agent_path in "$skill_path/agents/$cli"/*.md; do
      agent="$(basename "$agent_path" .md)"
      base="${skill}-${agent}.md"
      dst="$agents_dir/$base"
      if [[ "$MODE" == "link" ]]; then
        link_one "$agent_path" "$dst"
      else
        unlink_one "$dst" "$cli"
      fi
    done
  done
  shopt -u nullglob
}

for pair in "${PAIRS[@]}"; do
  IFS='|' read -r skills_dir agents_dir cli <<< "$pair"
  log ""
  log "[$cli] $skills_dir -> $agents_dir"
  process_pair "$skills_dir" "$agents_dir" "$cli"
done

log ""
log "done."
