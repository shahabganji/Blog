#!/usr/bin/env bash
# Prints a JSON snapshot of everything the review loop needs to decide its next step.
#
#   pr-state.sh <pr> [--wait]
#
# --wait blocks until the PR has settled for its head commit: Copilot's review run and the Gitar check (when they show up)
# are complete and no other check is queued or running. Gives up waiting for a bot that has not started within
# BOT_START_TIMEOUT seconds (default 900) and for everything after WAIT_TIMEOUT seconds (default 3600).
set -euo pipefail

PR="${1:?usage: pr-state.sh <pr> [--wait]}"
WAIT="${2:-}"
REPO="${REPO:-$(git remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')}"
OWNER="${REPO%/*}" NAME="${REPO#*/}"
POLL="${POLL_SECONDS:-30}"
BOT_START_TIMEOUT="${BOT_START_TIMEOUT:-900}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-3600}"
COPILOT_RUN="copilot-pull-request-reviewer"
GITAR_RUN="Gitar"

snapshot() {
  local pr checks statuses threads comments head
  pr="$(gh api "repos/$REPO/pulls/$PR")"
  head="$(jq -r .head.sha <<<"$pr")"
  checks="$(gh api --paginate "repos/$REPO/commits/$head/check-runs?per_page=100" --jq '.check_runs[]' \
    | jq -s 'map({name, app: .app.slug, status, conclusion, url: .html_url}) | group_by(.name) | map(last)')"
  statuses="$(gh api "repos/$REPO/commits/$head/status" \
    --jq '[.statuses[] | {name: .context, app: "status", status: (if .state == "pending" then "in_progress" else "completed" end), conclusion: .state, url: .target_url}]')"
  threads="$(gh api graphql -F owner="$OWNER" -F name="$NAME" -F pr="$PR" -f query='
    query($owner: String!, $name: String!, $pr: Int!) {
      repository(owner: $owner, name: $name) { pullRequest(number: $pr) { reviewThreads(first: 100) { nodes {
        id isResolved isOutdated path line
        comments(first: 30) { nodes { databaseId url author { login } body } } } } } } }' \
    --jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not)
           | {thread_id: .id, isOutdated, path, line, url: .comments.nodes[0].url, first_comment_id: .comments.nodes[0].databaseId,
              comments: [.comments.nodes[] | {author: .author.login, body}]}]')"
  comments="$(gh api --paginate "repos/$REPO/issues/$PR/comments?per_page=100" --jq '.[]' \
    | jq -s '[.[] | select(.user.type == "Bot" and (.body | contains("<!-- pr-quiz") | not))] | group_by(.user.login)
             | map(last | {author: .user.login, url: .html_url, updated_at, body: .body[0:6000]})')"
  jq -n --argjson pr "$pr" --argjson checks "$checks" --argjson statuses "$statuses" --argjson threads "$threads" \
    --argjson bot_comments "$comments" --arg copilot "$COPILOT_RUN" --arg gitar "$GITAR_RUN" '
    ($checks + $statuses) as $all
    | ($all | map(select(.name != "pr-quiz"))) as $gating
    | {
        pr: $pr.number, url: $pr.html_url, state: $pr.state, draft: $pr.draft, merged: $pr.merged,
        base: $pr.base.ref, head_ref: $pr.head.ref, head_sha: $pr.head.sha,
        updated_at: $pr.updated_at, mergeable_state: $pr.mergeable_state,
        copilot_review: ($all | map(select(.name == $copilot)) | first // {status: "absent"} | {status, conclusion}),
        gitar_review: ($all | map(select(.name == $gitar)) | first // {status: "absent"} | {status, conclusion}),
        pending_checks: [$gating[] | select(.status != "completed") | .name],
        failing_checks: [$gating[] | select(.status == "completed" and (.conclusion | IN("success", "neutral", "skipped") | not)) | {name, conclusion, url}],
        quiz_check: ($all | map(select(.name == "pr-quiz")) | first // {status: "absent"} | {status, conclusion}),
        unresolved_threads: $threads,
        bot_comments: $bot_comments
      }
    | .ready_for_quiz = (.state == "open" and (.pending_checks | length) == 0 and (.failing_checks | length) == 0
                         and (.unresolved_threads | length) == 0 and .copilot_review.status != "in_progress"
                         and .gitar_review.status != "in_progress")'
}

if [[ "$WAIT" != "--wait" ]]; then snapshot; exit 0; fi

start="$(date +%s)"
while :; do
  state="$(snapshot)"
  elapsed=$(( $(date +%s) - start ))
  waiting="$(jq -r --argjson elapsed "$elapsed" --argjson grace "$BOT_START_TIMEOUT" '
    [ (if (.pending_checks | length) > 0 then "checks: \(.pending_checks | join(", "))" else empty end),
      (if .copilot_review.status == "absent" and $elapsed < $grace and (.draft | not) then "Copilot review to start" else empty end),
      (if .gitar_review.status == "absent" and $elapsed < $grace and (.draft | not) then "Gitar review to start" else empty end)
    ] | join("; ")' <<<"$state")"
  if [[ -z "$waiting" ]]; then
    sleep 20 # bots post their review comments shortly after their check completes
    snapshot
    exit 0
  fi
  if (( elapsed >= WAIT_TIMEOUT )); then
    echo "timed out after ${elapsed}s waiting for: $waiting" >&2
    echo "$state"
    exit 3
  fi
  echo "[$(date +%H:%M:%S)] waiting for $waiting" >&2
  sleep "$POLL"
done
