# init.project.sh — project-specific gate checks for multi-cli-orchestrator.
# Sourced by init.sh from the PROJECT ROOT; inherits the `fail`/`ok` helpers.
# Project-owned: seeded once, survives `harness-install.sh` upgrades (unlike
# init.sh, which is harness BODY and gets overwritten).
#
# This repo is a distribution kit — its runtime artifacts are shell scripts shipped
# under skills/start-feature/scripts/. Verify they exist so agents fail fast rather
# than editing phantom files.
if [ -d "skills/start-feature/scripts" ]; then
  for s in invoke-worker.sh install-agents.sh harness-delegate.sh; do
    [ -f "skills/start-feature/scripts/$s" ] \
      || fail "skills/start-feature/scripts/$s missing (shipped worker harness)"
  done
  ok "shipped worker scripts present"
else
  echo "ℹ️  skills/start-feature/scripts not found — skipping script presence check" >&2
fi
