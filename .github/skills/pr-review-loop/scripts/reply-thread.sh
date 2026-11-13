#!/usr/bin/env bash
# Replies to a review thread and optionally resolves it.
#
#   reply-thread.sh <pr> <first_comment_id> <body-file | -> [--resolve <thread_id>]
#
# Both ids come from pr-state.sh (unresolved_threads[].first_comment_id and .thread_id). The body is read from a file
# (or stdin with "-") so that Markdown with backticks never passes through the shell.
set -euo pipefail

usage="usage: reply-thread.sh <pr> <first_comment_id> <body-file|-> [--resolve <thread_id>]"
PR="${1:?$usage}"
COMMENT_ID="${2:?$usage}"
BODY="${3:?$usage}"
REPO="${REPO:-$(git remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')}"
THREAD_ID=""
if [[ "${4:-}" == "--resolve" ]]; then THREAD_ID="${5:?$usage}"; elif [[ -n "${4:-}" ]]; then echo "$usage" >&2; exit 2; fi

[[ "$BODY" == "-" ]] && BODY=/dev/stdin
gh api "repos/$REPO/pulls/$PR/comments/$COMMENT_ID/replies" -F body=@"$BODY" --jq '"replied: \(.html_url)"'

if [[ -n "$THREAD_ID" ]]; then
  gh api graphql -f id="$THREAD_ID" -f query='mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { isResolved } } }' \
    --jq '"resolved: \(.data.resolveReviewThread.thread.isResolved)"'
fi
