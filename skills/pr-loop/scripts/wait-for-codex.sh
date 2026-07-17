#!/usr/bin/env bash
# wait-for-codex.sh — block until a Codex review lands on the PR's head commit.
#
# WHY THIS EXISTS
#   pr-loop is a runbook the model follows by hand inside an interactive session.
#   On its own, the model fetches the review state once, sees nothing yet, and ends
#   its turn — so a Codex review that lands minutes later goes unnoticed until a
#   human nudges "review again". This script is the missing wake mechanism: launch
#   it with the Bash tool's `run_in_background: true` and it polls every
#   MCO_POLL_INTERVAL seconds in the background. The instant Codex resolves (or the
#   ceiling is hit) it exits, and the harness re-invokes the session to classify
#   and fix. True minute-by-minute monitoring, no manual nudge, survives turns.
#
# Usage: wait-for-codex.sh <pr-number> <trigger-comment-id> <round-dir>
#   pr-number:          the open PR
#   trigger-comment-id: id of the `@codex review` issue comment (for the 👍 case)
#   round-dir:          .mco-cache/<pr>/round-<n>/ — where the 3 source files land
#
# Polls these env knobs (all optional):
#   MCO_POLL_INTERVAL   seconds between polls          (default 60)
#   MCO_POLL_CEILING    max seconds to wait before timeout (default 900 = 15 min)
#
# Exit codes (the caller branches on these):
#   0  → a Codex review with FRESH findings landed on head (created_at >= trigger).
#   3  → clean review, zero findings (summary banner on head as a review OR as an
#         issue comment, OR 👍 reaction on the trigger comment).
#   2  → timeout: ceiling hit with no resolution. Caller aborts round w/ needs-human.
#   4  → usage / precondition error.
#
# Always (re)writes pr.json, review-comments.json, issue-comments.json, reactions.json
# into round-dir on its final poll, so the caller reads the same sources the SKILL describes.

set -euo pipefail

PR_NUMBER="${1:-}"
TRIGGER_COMMENT_ID="${2:-}"
ROUND_DIR="${3:-}"

if [[ -z "$PR_NUMBER" || -z "$ROUND_DIR" ]]; then
  echo "usage: $0 <pr-number> <trigger-comment-id> <round-dir>" >&2
  exit 4
fi

INTERVAL="${MCO_POLL_INTERVAL:-60}"
CEILING="${MCO_POLL_CEILING:-900}"
CODEX_BOT="chatgpt-codex-connector"  # may carry a [bot] suffix via REST — prefix-match

mkdir -p "$ROUND_DIR"

read -r owner repo < <(gh repo view --json owner,name --jq '"\(.owner.login) \(.name)"')

# Freshness anchor: only inline comments created at/after the trigger count as this
# round's findings. GitHub re-stamps old unresolved threads' commit_id to each new
# head, so without this filter re-anchored stale threads masquerade as fresh findings
# and the clean path is never reached. Resolved once at startup (the trigger comment
# is immutable). Empty when no trigger id is passed → the filter is a no-op.
TRIGGER_TS=""
if [[ -n "$TRIGGER_COMMENT_ID" ]]; then
  # An id was provided → we MUST resolve its timestamp. An empty TS here would silently
  # disable the freshness filter for the whole wait and recreate the stale re-anchored-
  # thread bug this guard prevents. So retry a few times, then abort with a usage error
  # rather than proceeding blind. (Empty TS is reserved for the no-id compat path below.)
  for _attempt in 1 2 3; do
    TRIGGER_TS=$(gh api "repos/$owner/$repo/issues/comments/$TRIGGER_COMMENT_ID" \
      --jq '.created_at' 2>/dev/null || echo "")
    [[ -n "$TRIGGER_TS" ]] && break
    sleep 2
  done
  if [[ -z "$TRIGGER_TS" ]]; then
    echo "wait-for-codex: could not resolve trigger comment $TRIGGER_COMMENT_ID timestamp" \
         "— aborting so the freshness filter is not silently disabled" >&2
    exit 4
  fi
fi
# Persist the anchor so the SKILL's classification step (step 3) can apply the SAME
# freshness filter. The watcher only uses it for its exit decision; review-comments.json
# is written unfiltered (it's the raw source of truth), so without this the classifier
# would re-admit stale re-anchored threads into blocking.json — defeating the guard.
printf '%s' "$TRIGGER_TS" > "$ROUND_DIR/trigger-ts.txt"

# Fetch the sources into the round dir for this poll.
fetch_sources() {
  gh pr view "$PR_NUMBER" --json reviews,comments,statusCheckRollup,headRefOid \
    > "$ROUND_DIR/pr.json" 2>/dev/null || return 1
  gh api "repos/$owner/$repo/pulls/$PR_NUMBER/comments" --paginate --slurp 2>/dev/null \
    | jq 'add // []' > "$ROUND_DIR/review-comments.json" \
    || echo '[]' > "$ROUND_DIR/review-comments.json"
  # Issue comments via the PAGINATED REST endpoint. gh pr view --json comments caps at
  # first:100, so a clean banner (condition 2b) posted past page 1 would be missed and
  # an otherwise-clean PR would time out. This file is what condition 2b scans.
  gh api "repos/$owner/$repo/issues/$PR_NUMBER/comments" --paginate --slurp 2>/dev/null \
    | jq 'add // []' > "$ROUND_DIR/issue-comments.json" \
    || echo '[]' > "$ROUND_DIR/issue-comments.json"
  if [[ -n "$TRIGGER_COMMENT_ID" ]]; then
    gh api "repos/$owner/$repo/issues/comments/$TRIGGER_COMMENT_ID/reactions" \
      > "$ROUND_DIR/reactions.json" 2>/dev/null || echo '[]' > "$ROUND_DIR/reactions.json"
  else
    echo '[]' > "$ROUND_DIR/reactions.json"
  fi
}

# Evaluate the SKILL freshness conditions against the fetched sources.
# Echoes one of: findings | clean | pending. (The caller maps to an exit code.)
evaluate() {
  local head
  head=$(jq -r '.headRefOid // ""' "$ROUND_DIR/pr.json")
  [[ -z "$head" ]] && { echo pending; return; }
  local head_short="${head:0:7}"

  # Condition 1: FRESH inline findings filed by the Codex bot against the head commit.
  # The created_at >= trigger filter excludes stale threads that GitHub re-anchored to
  # head (their commit_id matches but they predate this round's trigger). No-op when
  # TRIGGER_TS is empty. ISO-8601 timestamps compare correctly as lexical strings.
  local findings
  findings=$(jq --arg bot "$CODEX_BOT" --arg head "$head" --arg since "$TRIGGER_TS" '
    [ .[] | select((.user.login // "") | startswith($bot))
          | select((.commit_id // "") == $head)
          | select($since == "" or ((.created_at // "") >= $since)) ] | length' \
    "$ROUND_DIR/review-comments.json" 2>/dev/null || echo 0)
  if [[ "${findings:-0}" -gt 0 ]]; then echo findings; return; fi

  # Condition 2: FRESH review summary banner naming the head commit, with zero findings.
  # submittedAt >= trigger excludes a banner from a PRIOR review of the same head (e.g. a
  # re-request without a new commit), which would otherwise flag the new round clean early.
  local banner
  banner=$(jq --arg bot "$CODEX_BOT" --arg sh "$head_short" --arg since "$TRIGGER_TS" '
    [ .reviews[]? | select((.author.login // "") | startswith($bot))
                 | select((.body // "") | contains("Reviewed commit") and contains($sh))
                 | select($since == "" or ((.submittedAt // "") >= $since)) ]
    | length' "$ROUND_DIR/pr.json" 2>/dev/null || echo 0)
  if [[ "${banner:-0}" -gt 0 ]]; then echo clean; return; fi

  # Condition 2b: the zero-findings banner delivered as an ISSUE comment, not a review.
  # Codex's clean result ("Didn't find any major issues. Breezy!" + "Reviewed commit:
  # <head>") posts to the issue-comment stream, which conditions 1/2 never scan — so a
  # genuinely clean PR would stall until the ceiling. Scan the PAGINATED issue-comments
  # file (REST → .user.login) so a banner past the first 100 comments is still caught.
  # Same created_at >= trigger freshness guard as condition 1 — a stale banner from a
  # prior review of this head must not flag the new round clean before Codex responds.
  local banner_issue
  banner_issue=$(jq --arg bot "$CODEX_BOT" --arg sh "$head_short" --arg since "$TRIGGER_TS" '
    [ .[]? | select((.user.login // "") | startswith($bot))
           | select((.body // "") | contains("Reviewed commit") and contains($sh))
           | select($since == "" or ((.created_at // "") >= $since)) ]
    | length' "$ROUND_DIR/issue-comments.json" 2>/dev/null || echo 0)
  if [[ "${banner_issue:-0}" -gt 0 ]]; then echo clean; return; fi

  # Condition 3: Codex bot reacted 👍 (+1) on the triggering comment.
  local thumbs
  thumbs=$(jq --arg bot "$CODEX_BOT" '
    [ .[]? | select((.content // "") == "+1")
           | select((.user.login // "") | startswith($bot)) ] | length' \
    "$ROUND_DIR/reactions.json" 2>/dev/null || echo 0)
  if [[ "${thumbs:-0}" -gt 0 ]]; then echo clean; return; fi

  echo pending
}

elapsed=0
while :; do
  if fetch_sources; then
    case "$(evaluate)" in
      findings) echo "wait-for-codex: review with findings landed on head (${elapsed}s)" >&2; exit 0 ;;
      clean)    echo "wait-for-codex: clean review, 0 findings (${elapsed}s)" >&2; exit 3 ;;
    esac
  else
    echo "wait-for-codex: gh fetch failed, retrying (${elapsed}s)" >&2
  fi

  if (( elapsed + INTERVAL > CEILING )); then
    echo "wait-for-codex: ceiling ${CEILING}s reached with no resolution — timeout" >&2
    exit 2
  fi
  sleep "$INTERVAL"
  elapsed=$(( elapsed + INTERVAL ))
done
