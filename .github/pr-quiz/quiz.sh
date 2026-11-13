#!/usr/bin/env bash
# PR comprehension quiz engine, shared by the pr-review-loop skill (build) and .github/workflows/pr-quiz.yml (sync).
#
#   quiz.sh validate <quiz.json>                                     check a private quiz spec (with answers)
#   quiz.sh build <quiz.json> <pr> <head-sha> <pr-url> [html-out]    print the PR comment body; optionally write the HTML page
#   quiz.sh check-answers <payload.json> <answers> <private-key>     grade answers against the encrypted key (prints JSON)
#   quiz.sh parse-answers <comment-body>                             normalise "/quiz B C A" -> "BCA" (exit 1 if malformed)
#   quiz.sh sync                                                     CI: grade new "/quiz ..." answers and update the pr-quiz check
#
# The answers never appear in clear text: they are encrypted with public.pem (RSA-OAEP) together with the PR number and head SHA,
# and only the pr-quiz workflow (environment "pr-quiz", secret PR_QUIZ_PRIVATE_KEY) can decrypt them.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS_MARK=90
MAX_ATTEMPTS=3
MIN_QUESTIONS=2
MAX_QUESTIONS=5
CHECK_NAME="pr-quiz"
PUBLIC_KEY="${QUIZ_PUBLIC_KEY:-$DIR/public.pem}"
GITHUB_ACTIONS_APP_ID=15368
MARKER="<!-- pr-quiz:v1 "
RESULT_MARKER="<!-- pr-quiz-result:v1 "
TRUSTED='["OWNER","MEMBER","COLLABORATOR"]'

die() { echo "error: $*" >&2; exit 1; }

validation_errors() { # $1 spec file, $2 "private" | "public"
  jq -r --arg mode "$2" --argjson min "$MIN_QUESTIONS" --argjson max "$MAX_QUESTIONS" '
    def need($f): if ((.[$f] // "") | tostring | length) == 0 then "\($f) is required" else empty end;
    need("title"), need("tldr"), need("why"), need("intent"),
    (if (.questions | type) != "array" or (.questions | length) < $min then "at least \($min) questions are required (one question can be guessed)" else empty end),
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

# ---------- CI (GH_TOKEN, REPO, PR, RUN_URL, PR_QUIZ_PRIVATE_KEY and optionally OUT_DIR are set by the workflow) ----------
#
# "sync" is idempotent: it re-reads every comment on the PR, grades each "/quiz" answer that has no result reply yet and then
# derives the pr-quiz check from the recorded results. A run that is cancelled or re-run therefore loses or repeats nothing.

reply() { # $1 answer comment id, $2 text, $3 extra marker fields (optional)
  gh api "repos/$REPO/issues/$PR/comments" -f body="$2"$'\n\n'"${RESULT_MARKER}answer=$1${3:+ $3} -->" >/dev/null
}

upsert_check() { # $1 sha, $2 status/conclusion JSON, $3 title, $4 summary
  local id fields
  fields="$(jq -c --arg title "$3" --arg summary "$4" --arg url "$RUN_URL" \
    '. + {details_url: $url, output: {title: $title, summary: $summary}}' <<<"$2")"
  id="$(gh api "repos/$REPO/commits/$1/check-runs?check_name=$CHECK_NAME&filter=latest" \
    --jq "[.check_runs[] | select(.app.id == $GITHUB_ACTIONS_APP_ID)][0].id // empty")"
  if [[ -n "$id" ]]; then
    gh api --method PATCH "repos/$REPO/check-runs/$id" --input - >/dev/null <<<"$fields"
  else
    jq -c --arg name "$CHECK_NAME" --arg sha "$1" '. + {name: $name, head_sha: $sha}' <<<"$fields" \
      | gh api --method POST "repos/$REPO/check-runs" --input - >/dev/null
  fi
}

fail_check() { # $1 sha, $2 title, $3 summary. Replaces an earlier pass: the latest quiz decides.
  upsert_check "$1" '{"status":"completed","conclusion":"failure"}' "$2" "$3"
}

reply_all() { # $1 answers JSON, $2 text
  jq -r '.[].id' <<<"$1" | while read -r id; do reply "$id" "$2"; done
}

cmd_sync() {
  local out="${OUT_DIR:-.}" head quiz quiz_id errors unreplied answers stale others attempts passed n
  local id node body given result
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  gh api --paginate "repos/$REPO/issues/$PR/comments?per_page=100" --jq '.[]' | jq -s 'sort_by(.id)' >"$tmp/comments.json"
  head="$(gh api "repos/$REPO/pulls/$PR" --jq .head.sha)"

  quiz="$(jq -c --arg m "$MARKER" --argjson trusted "$TRUSTED" \
    '[.[] | select((.author_association as $a | $trusted | index($a)) and (.body | contains($m)))] | last // empty' "$tmp/comments.json")"
  quiz_id=0
  if [[ -n "$quiz" ]]; then quiz_id="$(jq -r .id <<<"$quiz")"; fi

  # "/quiz" comments from trusted authors that have no result reply yet.
  unreplied="$(jq -c --argjson trusted "$TRUSTED" --arg r "$RESULT_MARKER" '
    [.[] | select(.user.login == "github-actions[bot]") | .body | capture("\($r)answer=(?<id>[0-9]+)")? | .id | tonumber] as $done
    | [.[] | select((.author_association as $a | $trusted | index($a)) and (.body | test("^\\s*/quiz"; "i"))
                    and (.id as $id | $done | index($id) | not))
         | {id, node_id, login: .user.login, body}]' "$tmp/comments.json")"
  answers="$(jq -c --argjson q "$quiz_id" '[.[] | select(.id > $q)]' <<<"$unreplied")"
  stale="$(jq -c --argjson q "$quiz_id" '[.[] | select(.id < $q)]' <<<"$unreplied")"

  if [[ -z "$quiz" ]]; then
    reply_all "$answers" "⚠️ There is no quiz on this PR yet."
    return 0
  fi
  # Answers to a quiz that was replaced before they were graded. No quiz fields, so they don't count as attempts.
  reply_all "$stale" "⚠️ A newer quiz was published before this answer was graded. Please answer the latest quiz."

  payload_from_body <<<"$(jq -r .body <<<"$quiz")" >"$tmp/payload.json" || true
  errors="$(validation_errors "$tmp/payload.json" public 2>&1 || echo "payload is not valid JSON")"
  if [[ -z "$errors" && "$(jq -r .pr "$tmp/payload.json")" != "$PR" ]]; then errors="the quiz was built for another PR"; fi
  if [[ -n "$errors" ]]; then
    reply_all "$answers" "⚠️ The latest quiz is invalid and can't be graded. Ask the author to publish a new one."
    fail_check "$head" "The latest quiz is invalid" "Publish a new quiz."
    die "invalid quiz in comment $quiz_id:"$'\n'"$errors"
  fi

  if [[ "$(jq -r .head_sha "$tmp/payload.json")" != "$head" ]]; then
    reply_all "$answers" "⚠️ The latest quiz covers commit \`$(jq -r '.head_sha[0:8]' "$tmp/payload.json")\`, but the PR now points at \`${head:0:8}\`. Wait for an updated quiz."
    echo "::notice::The latest quiz is for an older commit than the PR head ($head); nothing to grade."
    return 0
  fi

  # The check belongs to the commit, not the PR, so another open PR with the same head would share (and overwrite) it.
  others="$(gh api "repos/$REPO/commits/$head/pulls" \
    --jq "[.[] | select(.state == \"open\" and .head.sha == \"$head\" and .number != $PR) | \"#\\(.number)\"] | join(\", \")")"
  if [[ -n "$others" ]]; then
    reply_all "$answers" "⚠️ This commit is also the head of $others, and the \`$CHECK_NAME\` check belongs to the commit. Close the other PR, then answer again."
    fail_check "$head" "Head commit is shared with $others" "Each gated PR needs its own head commit. Close $others, then re-run this check or answer again."
    die "head commit $head is shared with $others"
  fi

  # Re-apply the server-side constants: a quiz comment cannot lower the pass mark or raise the attempt limit.
  public_spec "$tmp/payload.json" "$PR" "$head" "$(jq -r .pr_url "$tmp/payload.json")" >"$tmp/public.json"
  jq -r -f "$DIR/render-markdown.jq" "$tmp/public.json" >"$out/summary.md"
  jq -r -f "$DIR/render-html.jq" "$tmp/public.json" >"$out/pr-$PR-summary.html"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then cat "$out/summary.md" >>"$GITHUB_STEP_SUMMARY"; fi
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "html=$out/pr-$PR-summary.html" >>"$GITHUB_OUTPUT"; fi

  read -r attempts passed < <(jq -r --arg r "$RESULT_MARKER" --arg q "$quiz_id" '
    [.[] | select(.user.login == "github-actions[bot]") | .body
     | capture("\($r)answer=[0-9]+ quiz=(?<quiz>[0-9]+) sha=[0-9a-f]+ attempt=[0-9]+ passed=(?<passed>true|false)")? | select(.quiz == $q)]
    | "\(length) \(any(.passed == "true"))"' "$tmp/comments.json")
  n="$(jq '.questions | length' "$tmp/payload.json")"

  # Verify the answer key on every run until the quiz is passed, so a re-run without new answers still reports a broken key.
  if [[ "$passed" != "true" ]]; then
    (umask 077 && printf '%s\n' "${PR_QUIZ_PRIVATE_KEY:-}" >"$tmp/key.pem")
    if ! (cmd_check_answers "$tmp/payload.json" "$(printf "%${n}s" | tr " " A)" "$tmp/key.pem" >/dev/null); then
      rm -f "$tmp/key.pem"
      reply_all "$answers" "⚠️ This quiz can't be graded: its answer key could not be decrypted or doesn't match this PR (for example after a key rotation). Ask the author to publish a new quiz. This did not count as an attempt."
      fail_check "$head" "Quiz can't be graded" "The answer key could not be decrypted. Publish a new quiz."
      die "the answer key of quiz $quiz_id could not be decrypted or verified"
    fi
  fi

  while read -r answer <&3; do
    id="$(jq -r .id <<<"$answer")"; node="$(jq -r .node_id <<<"$answer")"; body="$(jq -r .body <<<"$answer")"
    if [[ "$passed" == "true" ]]; then reply "$id" "✅ This quiz has already been passed."; continue; fi
    if (( attempts >= MAX_ATTEMPTS )); then
      reply "$id" "⛔ No attempts left for this quiz. Re-read the summary and ask the author to publish a new quiz."; continue
    fi
    if ! given="$(cmd_parse_answers "$body")"; then
      reply "$id" "⚠️ Could not read your answers. Use one letter per question, in order, for example \`/quiz B C A\`. This did not count as an attempt."; continue
    fi
    if (( ${#given} != n )); then
      reply "$id" "⚠️ Expected $n answers but got ${#given}. This did not count as an attempt."; continue
    fi
    result="$(cmd_check_answers "$tmp/payload.json" "$given" "$tmp/key.pem")"
    attempts=$((attempts + 1))
    passed="$(jq -r .passed <<<"$result")"
    if [[ "$passed" == "true" ]]; then
      reply "$id" "✅ @$(jq -r .login <<<"$answer") passed the quiz ($(jq -r .score <<<"$result")%)." "quiz=$quiz_id sha=$head attempt=$attempts passed=true"
      # Hide the correct answers from later reviewers. Best effort only.
      gh api graphql -f id="$node" \
        -f query='mutation($id: ID!) { minimizeComment(input: {subjectId: $id, classifier: RESOLVED}) { clientMutationId } }' >/dev/null || true
    else
      # Only pass/fail is reported: a per-attempt score would tell the reviewer how many guesses were right.
      reply "$id" "❌ Not passed. The pass mark is ${PASS_MARK}%. Attempts left: $((MAX_ATTEMPTS - attempts))." "quiz=$quiz_id sha=$head attempt=$attempts passed=false"
    fi
  done 3< <(jq -c '.[]' <<<"$answers")
  rm -f "$tmp/key.pem"

  if [[ "$passed" == "true" ]]; then
    upsert_check "$head" '{"status":"completed","conclusion":"success"}' "Quiz passed" "$(cat "$out/summary.md")"
  elif (( attempts >= MAX_ATTEMPTS )); then
    fail_check "$head" "Quiz not passed, no attempts left" "Publish a new quiz to try again."$'\n\n'"$(cat "$out/summary.md")"
  else
    upsert_check "$head" '{"status":"in_progress"}' \
      "$(if (( attempts == 0 )); then echo "Waiting for a reviewer to pass the quiz"; else echo "Not passed yet ($attempts of $MAX_ATTEMPTS attempts used)"; fi)" \
      "Answer with a \`/quiz …\` PR comment."$'\n\n'"$(cat "$out/summary.md")"
  fi
  echo "PR #$PR quiz $quiz_id at $head: attempts=$attempts passed=$passed"
}

case "${1:-}" in
  validate) shift; cmd_validate "$@" ;;
  build) shift; cmd_build "$@" ;;
  check-answers) shift; cmd_check_answers "$@" ;;
  parse-answers) shift; cmd_parse_answers "$@" ;;
  sync) cmd_sync ;;
  *) sed -n '2,10p' "$0" >&2; exit 2 ;;
esac
