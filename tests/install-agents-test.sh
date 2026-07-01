#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/skills/start-feature/scripts/install-agents.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

make_skill() {
  local base="$1" skill="$2" cli="$3" agent="$4" ext="$5"
  mkdir -p "$base/$skill/agents/$cli"
  printf 'agent fixture\n' > "$base/$skill/agents/$cli/$agent.$ext"
}

assert_link_target() {
  local link="$1" target="$2"
  [[ -L "$link" ]] || fail "$link is not a symlink"
  local actual expected
  actual="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$link")"
  expected="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$target")"
  [[ "$actual" == "$expected" ]] || fail "$link points to $actual, expected $expected"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
PROJECT_DIR="$TMP/project"
mkdir -p "$HOME_DIR/.agents/skills" "$HOME_DIR/.gemini/config/skills" "$PROJECT_DIR/.agents/skills"

make_skill "$HOME_DIR/.agents/skills" pr-loop codex pr-fixer toml
make_skill "$HOME_DIR/.agents/skills" route-task antigravity routing-judge md
make_skill "$HOME_DIR/.gemini/config/skills" pr-loop antigravity pr-fixer md
make_skill "$PROJECT_DIR/.agents/skills" pr-loop codex pr-fixer toml
make_skill "$PROJECT_DIR/.agents/skills" route-task antigravity routing-judge md

HOME="$HOME_DIR" bash "$SCRIPT" --global >/tmp/install-agents-global.out
assert_link_target \
  "$HOME_DIR/.codex/agents/pr-loop-pr-fixer.toml" \
  "$HOME_DIR/.agents/skills/pr-loop/agents/codex/pr-fixer.toml"
assert_link_target \
  "$HOME_DIR/.gemini/config/agents/route-task-routing-judge.md" \
  "$HOME_DIR/.agents/skills/route-task/agents/antigravity/routing-judge.md"
assert_link_target \
  "$HOME_DIR/.gemini/config/agents/pr-loop-pr-fixer.md" \
  "$HOME_DIR/.gemini/config/skills/pr-loop/agents/antigravity/pr-fixer.md"

(
  cd "$PROJECT_DIR"
  HOME="$HOME_DIR" bash "$SCRIPT" --project >/tmp/install-agents-project.out
)
assert_link_target \
  "$PROJECT_DIR/.codex/agents/pr-loop-pr-fixer.toml" \
  "$PROJECT_DIR/.agents/skills/pr-loop/agents/codex/pr-fixer.toml"
assert_link_target \
  "$PROJECT_DIR/.agents/agents/route-task-routing-judge.md" \
  "$PROJECT_DIR/.agents/skills/route-task/agents/antigravity/routing-judge.md"

HOME="$HOME_DIR" bash "$SCRIPT" --global --unlink >/tmp/install-agents-unlink.out
[[ ! -e "$HOME_DIR/.codex/agents/pr-loop-pr-fixer.toml" ]] || fail "global codex link was not removed"
[[ ! -e "$HOME_DIR/.gemini/config/agents/route-task-routing-judge.md" ]] || fail "global antigravity link was not removed"

printf 'install-agents tests passed\n'
