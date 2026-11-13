#!/usr/bin/env bash
# PR comprehension quiz engine, shared by the pr-review-loop skill (build) and .github/workflows/pr-quiz.yml (publish, grade).
#
#   quiz.sh validate <quiz.json>                                     check a private quiz spec (with answers)
#   quiz.sh build <quiz.json> <pr> <head-sha> <pr-url> [html-out]    print the PR comment body; optionally write the HTML page
#   quiz.sh check-answers <payload.json> <answers> <private-key>     grade answers against the encrypted key (prints JSON)
#   quiz.sh parse-answers <comment-body>                             normalise "/quiz B C A" -> "BCA" (exit 1 if malformed)
#   quiz.sh publish                                                  CI: a quiz comment was posted -> pending pr-quiz check + HTML
#   quiz.sh grade                                                    CI: a "/quiz ..." comment was posted -> grade, report, update check
#
# The answers never appear in clear text: they are encrypted with public.pem (RSA-OAEP) together with the PR number and head SHA,
# and only the pr-quiz workflow (environment "pr-quiz", secret PR_QUIZ_PRIVATE_KEY) can decrypt them.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS_MARK=90
MAX_ATTEMPTS=3
MAX_QUESTIONS=5
CHECK_NAME="pr-quiz"
PUBLIC_KEY="${QUIZ_PUBLIC_KEY:-$DIR/public.pem}"
GITHUB_ACTIONS_APP_ID=15368
MARKER="<!-- pr-quiz:v1 "
RESULT_MARKER="<!-- pr-quiz-result:v1 "
TRUSTED='["OWNER","MEMBER","COLLABORATOR"]'

die() { echo "error: $*" >&2; exit 1; }

validation_errors() { # $1 spec file, $2 "private" | "public"
  jq -r --arg mode "$2" --argjson max "$MAX_QUESTIONS" '
    def need($f): if ((.[$f] // "") | tostring | length) == 0 then "\($f) is required" else empty end;
    need("title"), need("tldr"), need("why"), need("intent"),
    (if (.questions | type) != "array" or (.questions | length) == 0 then "at least one question is required" else empty end),
    (if (.questions // [] | length) > $max then "more than \($max) questions: the PR is too big, split it instead" else empty end),
    (if $mode == "public" and ((.ciphertext // "") == "") then "ciphertext is missing" else empty end),
    (.questions // [] | to_entries[] | .key as $i | .value |
      (if ((.question // "") | length) == 0 then "question \($i + 1): text is missing" else empty end),
      (if (.options | type) != "array" or (.options | length) != 4 then "question \($i + 1): needs exactly 4 options" else empty end),
      (if $mode == "private" and (((.answer // "") | test("^[A-Da-d]$")) | not) then "question \($i + 1): answer must be one of A-D" else empty end))
  ' "$1"
}

cmd_validate() {
  local errors
  errors="$(validation_errors "$1" private)"
  [[ -z "$errors" ]] || die "invalid quiz spec:"$'\n'"$errors"
}

public_spec() { # $1 spec file, $2 pr, $3 sha, $4 url -> public spec (answers removed, server-side constants applied)
  jq -c --argjson pr "$2" --arg sha "$3" --arg url "$4" --argjson pass "$PASS_MARK" --argjson attempts "$MAX_ATTEMPTS" '
    del(.ciphertext) | .questions |= map({question, options})
    | . + {version: 1, pr: $pr, pr_url: $url, head_sha: $sha, pass_mark: $pass, max_attempts: $attempts}' "$1"
}

cmd_build() {
  local spec="$1" pr="$2" sha="$3" url="$4" html="${5:-}"
  cmd_validate "$spec"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "head sha must be a full 40-character commit sha"
  local answers key public
  answers="$(jq -r '[.questions[].answer | ascii_upcase] | join("")' "$spec")"
  key="$(jq -cn --argjson pr "$pr" --arg sha "$sha" --arg answers "$answers" '{pr: $pr, sha: $sha, answers: $answers}' \
    | openssl pkeyutl -encrypt -pubin -inkey "$PUBLIC_KEY" -pkeyopt rsa_padding_mode:oaep | openssl base64 -A)"
  public="$(public_spec "$spec" "$pr" "$sha" "$url")"
  jq -r -f "$DIR/render-markdown.jq" <<<"$public"
  printf '\n%s%s -->\n' "$MARKER" "$(jq -c --arg key "$key" '. + {ciphertext: $key}' <<<"$public" | openssl base64 -A)"
  if [[ -n "$html" ]]; then jq -r -f "$DIR/render-html.jq" <<<"$public" >"$html"; fi
}

payload_from_body() { # stdin: comment body -> payload JSON (empty if none)
  local b64
  b64="$(grep -o "${MARKER}[A-Za-z0-9+/=]* -->" | tail -1 | sed -e "s|^${MARKER}||" -e 's| -->$||' || true)"
  [[ -n "$b64" ]] && openssl base64 -d -A <<<"$b64"
}

cmd_parse_answers() {
  local first rest
  first="$(printf '%s\n' "$1" | head -1 | tr '[:lower:]' '[:upper:]')"
  [[ "$first" =~ ^[[:space:]]*/QUIZ([[:space:]]|$) ]] || return 1
  rest="$(sed -E 's#^[[:space:]]*/QUIZ##; s/[0-9]+//g; s/[][[:space:],;.:()-]//g' <<<"$first")"
  [[ "$rest" =~ ^[A-D]+$ ]] || return 1
  echo "$rest"
}

cmd_check_answers() { # $1 payload file, $2 answers, $3 private key file
  local key
  key="$(jq -r .ciphertext "$1" | openssl base64 -d -A | openssl pkeyutl -decrypt -inkey "$3" -pkeyopt rsa_padding_mode:oaep)" \
    || die "could not decrypt the answer key"
  jq -cn --argjson payload "$(cat "$1")" --argjson key "$key" --arg given "$2" --argjson pass "$PASS_MARK" '
    if $key.pr != $payload.pr or $key.sha != $payload.head_sha then error("answer key does not belong to this PR and commit") else . end
    | ($key.answers | length) as $total
    | ([range(0; $total) | select($given[.:.+1] == $key.answers[.:.+1])] | length) as $correct
    | {correct: $correct, total: $total, score: (($correct * 100 / $total) | floor), passed: ($correct * 100 >= $pass * $total)}'
}

# ---------- CI helpers (GH_TOKEN, REPO, PR, COMMENT_BODY, RUN_URL are set by the workflow) ----------

comment() { gh api "repos/$REPO/issues/$PR/comments" -f body="$1" >/dev/null; }

upsert_check() { # $1 sha, $2 JSON fields (status/conclusion/output)
  local id
  id="$(gh api "repos/$REPO/commits/$1/check-runs?check_name=$CHECK_NAME&filter=latest" \
    --jq "[.check_runs[] | select(.app.id == $GITHUB_ACTIONS_APP_ID)][0].id // empty")"
  if [[ -n "$id" ]]; then
    jq -c --arg url "$RUN_URL" '. + {details_url: $url}' <<<"$2" | gh api --method PATCH "repos/$REPO/check-runs/$id" --input - >/dev/null
  else
    jq -c --arg name "$CHECK_NAME" --arg sha "$1" --arg url "$RUN_URL" '. + {name: $name, head_sha: $sha, details_url: $url}' <<<"$2" \
      | gh api --method POST "repos/$REPO/check-runs" --input - >/dev/null
  fi
}

check_fields() { # $1 status/conclusion JSON, $2 title, $3 summary
  jq -c --arg title "$2" --arg summary "$3" '. + {output: {title: $title, summary: $summary}}' <<<"$1"
}

pr_head() { gh api "repos/$REPO/pulls/$PR" --jq .head.sha; }

cmd_publish() {
  local payload errors head out="${OUT_DIR:-.}"
  payload="$(payload_from_body <<<"$COMMENT_BODY")" || true
  [[ -n "$payload" ]] || die "comment has no quiz payload"
  printf '%s' "$payload" >"$out/payload.json"
  errors="$(validation_errors "$out/payload.json" public)"
  [[ -z "$errors" ]] || die "invalid quiz payload:"$'\n'"$errors"
  [[ "$(jq -r .pr "$out/payload.json")" == "$PR" ]] || die "quiz payload is for another PR"
  head="$(pr_head)"
  if [[ "$(jq -r .head_sha "$out/payload.json")" != "$head" ]]; then
    echo "::notice::Quiz is for an older commit than the PR head ($head); ignoring it."
    exit 0
  fi
  # Re-apply the server-side constants: the publisher cannot lower the pass mark or raise the attempt limit.
  public_spec "$out/payload.json" "$PR" "$head" "$(jq -r .pr_url "$out/payload.json")" >"$out/public.json"
  jq -r -f "$DIR/render-markdown.jq" "$out/public.json" >"$out/summary.md"
  jq -r -f "$DIR/render-html.jq" "$out/public.json" >"$out/pr-$PR-summary.html"
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && cat "$out/summary.md" >>"$GITHUB_STEP_SUMMARY"
  upsert_check "$head" "$(check_fields '{"status":"in_progress"}' "Waiting for a reviewer to pass the quiz" "$(cat "$out/summary.md")")"
  [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "html=$out/pr-$PR-summary.html" >>"$GITHUB_OUTPUT"
  echo "Published quiz for PR #$PR at $head"
}

cmd_grade() {
  local answers comments quiz quiz_id head results attempts n result passed score text status
  if ! answers="$(cmd_parse_answers "$COMMENT_BODY")"; then
    comment "⚠️ Could not read your answers. Use one letter per question, in order, for example \`/quiz B C A\`."
    return 0
  fi
  comments="$(gh api --paginate "repos/$REPO/issues/$PR/comments?per_page=100" --jq '.[]' | jq -s .)"
  quiz="$(jq -c --arg m "$MARKER" --argjson trusted "$TRUSTED" \
    '[.[] | select((.author_association as $a | $trusted | index($a)) and (.body | contains($m)))] | last // empty' <<<"$comments")"
  if [[ -z "$quiz" ]]; then comment "⚠️ There is no quiz on this PR yet."; return 0; fi
  quiz_id="$(jq -r .id <<<"$quiz")"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  payload_from_body <<<"$(jq -r .body <<<"$quiz")" >"$tmp/payload.json"
  head="$(pr_head)"
  if [[ "$(jq -r .head_sha "$tmp/payload.json")" != "$head" ]]; then
    comment "⚠️ The latest quiz covers commit \`$(jq -r '.head_sha[0:8]' "$tmp/payload.json")\`, but the PR now points at \`${head:0:8}\`. Wait for an updated quiz."
    return 0
  fi
  results="$(jq -c --arg m "${RESULT_MARKER}quiz=$quiz_id " \
    '[.[] | select(.user.login == "github-actions[bot]" and (.body | contains($m))) | .body]' <<<"$comments")"
  if jq -e 'any(.[]; contains("passed=true"))' <<<"$results" >/dev/null; then comment "✅ This quiz has already been passed."; return 0; fi
  attempts="$(jq length <<<"$results")"
  if (( attempts >= MAX_ATTEMPTS )); then
    comment "⛔ No attempts left for this quiz ($MAX_ATTEMPTS used). Re-read the summary and ask the author to publish a new quiz."
    return 0
  fi
  n="$(jq '.questions | length' "$tmp/payload.json")"
  if (( ${#answers} != n )); then comment "⚠️ Expected $n answers but got ${#answers}. This did not count as an attempt."; return 0; fi

  umask 077
  printf '%s\n' "$PR_QUIZ_PRIVATE_KEY" >"$tmp/key.pem"
  result="$(cmd_check_answers "$tmp/payload.json" "$answers" "$tmp/key.pem")"
  rm -f "$tmp/key.pem"
  attempts=$((attempts + 1))
  passed="$(jq -r .passed <<<"$result")"
  score="$(jq -r '"\(.correct)/\(.total) (\(.score)%)"' <<<"$result")"
  if [[ "$passed" == "true" ]]; then
    text="✅ @${ACTOR} passed the quiz: $score."
    upsert_check "$head" "$(check_fields '{"status":"completed","conclusion":"success"}' "Passed: $score" "Passed by @$ACTOR on attempt $attempts.")"
  elif (( attempts >= MAX_ATTEMPTS )); then
    text="❌ $score. The pass mark is ${PASS_MARK}% and no attempts are left."
    upsert_check "$head" "$(check_fields '{"status":"completed","conclusion":"failure"}' "Failed: $score" "No attempts left. A new quiz is needed.")"
  else
    status="$(check_fields '{"status":"in_progress"}' "Attempt $attempts scored $score" "Pass mark ${PASS_MARK}%. Attempts left: $((MAX_ATTEMPTS - attempts)).")"
    text="❌ $score. The pass mark is ${PASS_MARK}%. Attempts left: $((MAX_ATTEMPTS - attempts))."
    upsert_check "$head" "$status"
  fi
  comment "$text"$'\n\n'"${RESULT_MARKER}quiz=$quiz_id sha=$head attempt=$attempts passed=$passed -->"
  if [[ "$passed" == "true" && -n "${COMMENT_NODE_ID:-}" ]]; then
    # Hide the correct answers from later reviewers. Best effort only.
    gh api graphql -f id="$COMMENT_NODE_ID" \
      -f query='mutation($id: ID!) { minimizeComment(input: {subjectId: $id, classifier: RESOLVED}) { clientMutationId } }' >/dev/null || true
  fi
}

case "${1:-}" in
  validate) shift; cmd_validate "$@" ;;
  build) shift; cmd_build "$@" ;;
  check-answers) shift; cmd_check_answers "$@" ;;
  parse-answers) shift; cmd_parse_answers "$@" ;;
  publish) cmd_publish ;;
  grade) cmd_grade ;;
  *) sed -n '2,10p' "$0" >&2; exit 2 ;;
esac
