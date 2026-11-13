#!/usr/bin/env bash
# Publishes the PR summary + comprehension quiz on the PR's pr-quiz check (no PR comment) and writes the HTML summary locally.
#
#   publish-quiz.sh <pr> <quiz.json> [--dry-run]
#
# quiz.json is the private spec (with answers), see ../quiz-spec.example.json. Never commit it.
# The answers are encrypted with .github/pr-quiz/public.pem; the payload, the check and the HTML only contain the questions.
# The payload is handed to the "PR quiz: publish" workflow, which validates it and updates the check. Publishing again
# replaces the quiz and resets the attempts.
set -euo pipefail

PR="${1:?usage: publish-quiz.sh <pr> <quiz.json> [--dry-run]}"
SPEC="${2:?missing quiz.json}"
DRY_RUN="${3:-}"
REPO="${REPO:-$(git remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')}"
QUIZ="$(git rev-parse --show-toplevel)/.github/pr-quiz/quiz.sh"
OUT="${OUT_DIR:-${TMPDIR:-/tmp}}"
WORKFLOW="pr-quiz-publish.yml"

read -r HEAD URL < <(gh api "repos/$REPO/pulls/$PR" --jq '"\(.head.sha) \(.html_url)"')
PAYLOAD="$("$QUIZ" build "$SPEC" "$PR" "$HEAD" "$URL" "$OUT")"
echo "HTML summary:          $OUT/pr-$PR-summary.html"
echo "Check summary preview: $OUT/pr-$PR-quiz.md"

if [[ "$DRY_RUN" == "--dry-run" ]]; then
  echo "Dry run: nothing published."
  exit 0
fi

default_branch="$(gh api "repos/$REPO" --jq .default_branch)"
if ! gh api "repos/$REPO/contents/.github/workflows/$WORKFLOW?ref=$default_branch" --silent 2>/dev/null; then
  echo "error: $WORKFLOW is not on the default branch ($default_branch), so the quiz can't be published yet." >&2
  echo "       Run .github/pr-quiz/setup.sh --activate (see .github/pr-quiz/README.md). Share the HTML summary meanwhile." >&2
  exit 1
fi

run_id="$(gh api --method POST "repos/$REPO/actions/workflows/$WORKFLOW/dispatches" \
  -f ref="$default_branch" -f "inputs[pr]=$PR" -f "inputs[quiz]=$PAYLOAD" -F return_run_details=true --jq .workflow_run_id)"
echo "Publishing: $(gh api "repos/$REPO/actions/runs/$run_id" --jq .html_url)"
if ! gh run watch "$run_id" --repo "$REPO" --exit-status >/dev/null; then
  gh run view "$run_id" --repo "$REPO" --log-failed | tail -20 >&2
  exit 1
fi
gh api "repos/$REPO/commits/$HEAD/check-runs?check_name=pr-quiz&filter=all&per_page=100" \
  --jq '.check_runs | max_by(.id) | "Quiz published: \(.html_url) (\(.output.title))"'
