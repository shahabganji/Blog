#!/usr/bin/env bash
# Replies to a review thread and optionally resolves it.
#
#   reply-thread.sh <pr> <first-comment-id> <body-file | -> [--resolve]
#
# <first-comment-id> is "first_comment_id" from pr-state.sh. The body is read from a file (or stdin with "-") so that
# Markdown with backticks never passes through the shell.
set -euo pipefail

PR="${1:?usage: reply-thread.sh <pr> <first-comment-id> <body-file|-> [--resolve]}"
COMMENT_ID="${2:?missing comment id}"
BODY="${3:?missing body file}"
RESOLVE="${4:-}"
REPO="${REPO:-$(git remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')}"

[[ "$BODY" == "-" ]] && BODY=/dev/stdin
gh api "repos/$REPO/pulls/$PR/comments/$COMMENT_ID/replies" -F body=@"$BODY" --jq '"replied: \(.html_url)"'

if [[ "$RESOLVE" == "--resolve" ]]; then
  thread="$(gh api graphql -F owner="${REPO%/*}" -F name="${REPO#*/}" -F pr="$PR" -f query='
    query($owner: String!, $name: String!, $pr: Int!) {
      repository(owner: $owner, name: $name) { pullRequest(number: $pr) { reviewThreads(first: 100) { nodes {
        id comments(first: 1) { nodes { databaseId } } } } } } }' \
    --jq ".data.repository.pullRequest.reviewThreads.nodes[] | select(.comments.nodes[0].databaseId == $COMMENT_ID) | .id")"
  [[ -n "$thread" ]] || { echo "no thread starts with comment $COMMENT_ID" >&2; exit 1; }
  gh api graphql -f id="$thread" -f query='mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { isResolved } } }' \
    --jq '"resolved: \(.data.resolveReviewThread.thread.isResolved)"'
fi
