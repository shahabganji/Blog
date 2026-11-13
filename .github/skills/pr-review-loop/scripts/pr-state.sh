#!/usr/bin/env bash
# Prints a JSON snapshot of everything the review loop needs to decide its next step.
#
#   pr-state.sh <pr> [--wait]
#
# "ready_for_quiz" requires a completed review on the head commit from every bot in REQUIRED_BOTS (default "copilot gitar"),
# no pending or failing checks (pr-quiz aside) and no unresolved threads. A missing review is listed in "missing_reviews".
#
# --wait blocks until the PR has settled for its head commit: the required reviews are complete and no other check is queued or
# running. Stops waiting for a review that has not started within BOT_START_TIMEOUT seconds (default 900), and for everything
# after WAIT_TIMEOUT seconds (default 3600).
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
REQUIRED_BOTS="${REQUIRED_BOTS-copilot gitar}"

snapshot() {
  local pr checks statuses threads comments head
  pr="$(gh api "repos/$REPO/pulls/$PR")"
  head="$(jq -r .head.sha <<<"$pr")"
  checks="$(gh api --paginate "repos/$REPO/commits/$head/check-runs?per_page=100" --jq '.check_runs[]' \
    | jq -s 'map({name, app: .app.slug, status, conclusion, url: .html_url}) | group_by(.name) | map(last)')"
  statuses="$(gh api "repos/$REPO/commits/$head/status" \
    --jq '[.statuses[] | {name: .context, app: "status", status: (if .state == "pending" then "in_progress" else "completed" end), conclusion: .state, url: .target_url}]')"
  # All threads (paginated); per thread the opening comment plus the 30 most recent replies.
  threads="$(gh api graphql --paginate -F owner="$OWNER" -F name="$NAME" -F pr="$PR" -f query='
    query($owner: String!, $name: String!, $pr: Int!, $endCursor: String) {
      repository(owner: $owner, name: $name) { pullRequest(number: $pr) {
        reviewThreads(first: 100, after: $endCursor) { pageInfo { hasNextPage endCursor } nodes {
          id isResolved isOutdated path line
          root: comments(first: 1) { nodes { databaseId url author { login } body } }
          recent: comments(last: 30) { totalCount nodes { databaseId author { login } body } } } } } } }' \
    --jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not)
           | .root.nodes[0] as $root
           | {thread_id: .id, isOutdated, path, line, url: $root.url, first_comment_id: $root.databaseId, comment_count: .recent.totalCount,
              comments: ([{author: $root.author.login, body: $root.body}]
                         + [.recent.nodes[] | select(.databaseId != $root.databaseId) | {author: .author.login, body}])}]' \
    | jq -s 'add // []')"
  comments="$(gh api --paginate "repos/$REPO/issues/$PR/comments?per_page=100" --jq '.[]' \
    | jq -s '[.[] | select(.user.type == "Bot" and (.body | contains("<!-- pr-quiz") | not))] | group_by(.user.login)
             | map(last | {author: .user.login, url: .html_url, updated_at, body})')"
  jq -n --argjson pr "$pr" --argjson checks "$checks" --argjson statuses "$statuses" --argjson threads "$threads" \
    --argjson bot_comments "$comments" --arg copilot "$COPILOT_RUN" --arg gitar "$GITAR_RUN" --arg required "$REQUIRED_BOTS" '
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
    | .missing_reviews = [($required | split(" ") | map(select(. != ""))[]) as $bot
                          | select(.["\($bot)_review"].status != "completed") | $bot]
    | .ready_for_quiz = (.state == "open" and (.pending_checks | length) == 0 and (.failing_checks | length) == 0
                         and (.unresolved_threads | length) == 0 and (.missing_reviews | length) == 0)'
}

if [[ "$WAIT" != "--wait" ]]; then snapshot; exit 0; fi

start="$(date +%s)"
while :; do
  state="$(snapshot)"
  elapsed=$(( $(date +%s) - start ))
  waiting="$(jq -r --argjson elapsed "$elapsed" --argjson grace "$BOT_START_TIMEOUT" '
    [ (if (.pending_checks | length) > 0 then "checks: \(.pending_checks | join(", "))" else empty end),
      (.missing_reviews[] as $bot | select(.["\($bot)_review"].status == "absent" and $elapsed < $grace and (.draft | not))
       | "\($bot) review to start")
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
