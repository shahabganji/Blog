#!/usr/bin/env bash
# Publishes the PR summary + comprehension quiz as a PR comment and writes the HTML summary locally.
#
#   publish-quiz.sh <pr> <quiz.json> [--dry-run]
#
# quiz.json is the private spec (with answers), see ../quiz-spec.example.json. Never commit it.
# The answers are encrypted with .github/pr-quiz/public.pem; the comment and the HTML only contain the questions.
# Older quiz comments on the PR are minimized as outdated.
set -euo pipefail

PR="${1:?usage: publish-quiz.sh <pr> <quiz.json> [--dry-run]}"
SPEC="${2:?missing quiz.json}"
DRY_RUN="${3:-}"
REPO="${REPO:-$(git remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')}"
QUIZ="$(git rev-parse --show-toplevel)/.github/pr-quiz/quiz.sh"
OUT="${OUT_DIR:-${TMPDIR:-/tmp}}"
HTML="$OUT/pr-$PR-summary.html"
BODY="$OUT/pr-$PR-quiz-comment.md"

read -r HEAD URL < <(gh api "repos/$REPO/pulls/$PR" --jq '"\(.head.sha) \(.html_url)"')
"$QUIZ" build "$SPEC" "$PR" "$HEAD" "$URL" "$HTML" >"$BODY"
echo "HTML summary: $HTML"

if [[ "$DRY_RUN" == "--dry-run" ]]; then
  echo "Comment body (not posted): $BODY"
  exit 0
fi

old="$(gh api --paginate "repos/$REPO/issues/$PR/comments?per_page=100" --jq '.[] | select(.body | contains("<!-- pr-quiz:v1 ")) | .node_id')"
gh api "repos/$REPO/issues/$PR/comments" -F body=@"$BODY" --jq '"Quiz posted: \(.html_url)"'
for id in $old; do
  gh api graphql -f id="$id" -f query='mutation($id: ID!) { minimizeComment(input: {subjectId: $id, classifier: OUTDATED}) { clientMutationId } }' >/dev/null || true
done

default_branch="$(gh api "repos/$REPO" --jq .default_branch)"
if ! gh api "repos/$REPO/contents/.github/workflows/pr-quiz.yml?ref=$default_branch" --silent 2>/dev/null; then
  echo "warning: pr-quiz.yml is not on the default branch ($default_branch), so the quiz cannot be graded yet." >&2
  echo "         Run .github/pr-quiz/setup.sh --activate (see .github/pr-quiz/README.md)." >&2
fi
