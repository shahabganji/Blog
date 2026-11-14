#!/usr/bin/env bash
# PR comprehension quiz engine, shared by the pr-review-loop skill (build) and .github/workflows/pr-quiz.yml (sync).
#
#   quiz.sh validate <quiz.json>                                   check a private quiz spec (with answers)
#   quiz.sh build <quiz.json> <pr> <head-sha> <pr-url> <out-dir>   print the encrypted payload; write the check summary preview
#                                                                  (pr-<n>-quiz.md) and the HTML page (pr-<n>-summary.html)
#   quiz.sh check-answers <payload.json> <answers> <private-key>   grade answers against the encrypted key (prints JSON)
#   quiz.sh publish                                                CI (pr-quiz-publish.yml): put a quiz on the PR's pr-quiz check
#   quiz.sh answer                                                 CI (pr-quiz.yml, pr-quiz-comment.yml): grade one reviewer's answers
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
STATE_MARKER="<!-- pr-quiz-state:v1 "
FORM_MARKER="<!-- pr-quiz-form:v1 "
BOT_LOGIN="github-actions[bot]"
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

# The quiz ID names one build of a quiz. Reviewers enter it in the answer form, so an answer to a quiz that has since been
# replaced is refused instead of being graded against the new one. It is derived from the encrypted key, so it can't be
# chosen independently of the answers.
quiz_id() { printf '%s' "$1" | openssl dgst -sha256 -r | cut -c1-6; } # $1 ciphertext

public_spec() { # $1 spec file, $2 pr, $3 sha, $4 url, $5 quiz id -> public spec (answers removed, server-side constants applied)
  jq -c --argjson pr "$2" --arg sha "$3" --arg url "$4" --arg id "$5" --argjson pass "$PASS_MARK" --argjson attempts "$MAX_ATTEMPTS" \
    --argjson allow_author "$([[ "${ALLOW_AUTHOR:-}" == "true" ]] && echo true || echo false)" '
    del(.ciphertext) | .questions |= map({question, options})
    | . + {version: 1, pr: $pr, pr_url: $url, head_sha: $sha, quiz_id: $id, pass_mark: $pass, max_attempts: $attempts,
           allow_author: $allow_author}' "$1"
}

cmd_build() {
  local spec="$1" pr="$2" sha="$3" url="$4" out="$5"
  cmd_validate "$spec"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "head sha must be a full 40-character commit sha"
  local answers key public
  answers="$(jq -r '[.questions[].answer | ascii_upcase] | join("")' "$spec")"
  key="$(jq -cn --argjson pr "$pr" --arg sha "$sha" --arg answers "$answers" '{pr: $pr, sha: $sha, answers: $answers}' \
    | openssl pkeyutl -encrypt -pubin -inkey "$PUBLIC_KEY" -pkeyopt rsa_padding_mode:oaep | openssl base64 -A)"
  public="$(public_spec "$spec" "$pr" "$sha" "$url" "$(quiz_id "$key")")"
  jq -r -L "$DIR" -f "$DIR/render-markdown.jq" <<<"$public" >"$out/pr-$pr-quiz.md"
  jq -r -f "$DIR/render-html.jq" <<<"$public" >"$out/pr-$pr-summary.html"
  jq -c --arg key "$key" '. + {ciphertext: $key}' <<<"$public" | openssl base64 -A
  echo
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

# ---------- CI ----------
# Set by the workflows: GH_TOKEN, REPO, PR, RUN_URL, PR_QUIZ_PRIVATE_KEY, optionally OUT_DIR, GITHUB_STEP_SUMMARY, GITHUB_OUTPUT.
# publish also gets QUIZ (the payload printed by "build"); answer gets ACTOR and reads the answers from GITHUB_EVENT_PATH (the
# q1..q5 form inputs, or the ticked boxes of the edited quiz comment), so they never show up in the log (Actions prints env values).
#
# The pr-quiz check on the PR head is the only state. Its summary shows the summary and quiz; its text holds the encrypted
# payload and the recorded attempts in hidden markers. Only workflows with checks: write can change it, and both quiz workflows
# share a concurrency group per PR, so updates never interleave. The quiz comment on the PR is only the answer form: it is
# rewritten from the check after every publish and answer, and nothing in it is trusted except which boxes are ticked.

note() { # $1 Markdown for whoever started the run: printed and added to the job summary
  printf '%s\n' "$1"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then printf '%s\n\n' "$1" >>"$GITHUB_STEP_SUMMARY"; fi
}

stop() { # refuse the run; the check is left as it is
  note "$1"
  if [[ -n "${COMMENT_ID:-}" ]]; then # answered in the quiz comment: show the reason there instead of the form
    write_comment "$FORM_MARKER""pr=$PR quiz=none -->"$'\n'"### 📝 PR quiz"$'\n\n'"$1" || true
  fi
  exit 1
}

refuse() { # $1 message, $2 boxes to keep ticked (JSON, [] clears them): refuse the answer and show why in the quiz comment
  if [[ -n "${COMMENT_ID:-}" ]]; then
    write_form "$tmp/public.json" "$state" "$1" "$2" || true
    COMMENT_ID=""
  fi
  stop "$1"
}

write_comment() { # $1 body: update the quiz comment on the PR, or create it
  local id="${COMMENT_ID:-}"
  if [[ -z "$id" ]]; then
    id="$(gh api --paginate "repos/$REPO/issues/$PR/comments" \
      --jq ".[] | select(.user.login == \"$BOT_LOGIN\" and (.body | startswith(\"$FORM_MARKER\"))) | .id" | tail -n1)"
  fi
  if [[ -n "$id" ]]; then
    jq -n --arg b "$1" '{body: $b}' | gh api --method PATCH "repos/$REPO/issues/comments/$id" --input - >/dev/null
  else
    jq -n --arg b "$1" '{body: $b}' | gh api --method POST "repos/$REPO/issues/$PR/comments" --input - >/dev/null
  fi
}

write_form() { # $1 public spec file, $2 state JSON, $3 notice, $4 ticked boxes per question (JSON): render the quiz comment
  local open body
  # Open while nobody has passed and someone may still answer (no reviewer requested yet counts: one can be requested).
  open="$(jq -n --argjson s "$2" --argjson r "$reviewers" --argjson max "$MAX_ATTEMPTS" \
    '($s.results | any(.passed) | not) and (($r | length) == 0 or any($r[]; . as $l | ([$s.results[] | select(.by == $l)] | length) < $max))')"
  if ! body="$(jq -c --argjson open "$open" --arg notice "$3" --argjson sel "$4" '. + {form: {open: $open, notice: $notice, selected: $sel}}' "$1" \
      | jq -r -L "$DIR" -f "$DIR/render-comment.jq")" || ! write_comment "$body"; then
    note "⚠️ The quiz comment on PR #$PR could not be updated; the \`$CHECK_NAME\` check is up to date."
  fi
}

latest_check() { # $1 sha -> the latest pr-quiz check run created by GitHub Actions, or {}
  gh api "repos/$REPO/commits/$1/check-runs?check_name=$CHECK_NAME&filter=all&per_page=100" \
    --jq "[.check_runs[] | select(.app.id == $GITHUB_ACTIONS_APP_ID)] | max_by(.id) // {}"
}

upsert_check() { # $1 sha, $2 status/conclusion JSON, $3 title, $4 summary, $5 text, $6 details url
  local id fields
  fields="$(jq -c --arg title "$3" --arg summary "$4" --arg text "$5" --arg url "$6" \
    '. + {details_url: $url, output: {title: $title, summary: $summary, text: $text}}' <<<"$2")"
  # A completed check run can't go back to pending, so a new quiz after a pass or failure gets a new run. The ruleset and
  # latest_check both use the newest run.
  id="$(latest_check "$1" | jq -r --argjson f "$fields" 'select(.status != "completed" or $f.status == "completed") | .id // empty')"
  if [[ -n "$id" ]]; then
    gh api --method PATCH "repos/$REPO/check-runs/$id" --input - >/dev/null <<<"$fields"
  else
    jq -c --arg name "$CHECK_NAME" --arg sha "$1" '. + {name: $name, head_sha: $sha}' <<<"$fields" \
      | gh api --method POST "repos/$REPO/check-runs" --input - >/dev/null
  fi
}

marker_value() { # $1 check JSON, $2 marker -> the value of the last "<marker>value -->" line in the check text
  jq -r --arg m "$2" '[.output.text // "" | split("\n")[] | select(startswith($m)) | ltrimstr($m) | rtrimstr(" -->")] | last // empty' <<<"$1"
}

load_pr() { # sets pr_json, head, reviewers; refuses closed PRs and head commits shared with another open PR
  local others author
  [[ "$PR" =~ ^[0-9]+$ ]] || stop "❌ \`$PR\` is not a pull request number."
  pr_json="$(gh api "repos/$REPO/pulls/$PR")"
  [[ "$(jq -r .state <<<"$pr_json")" == "open" ]] || stop "❌ PR #$PR is not open."
  head="$(jq -r .head.sha <<<"$pr_json")"
  # Only people asked to review the PR may answer: requested reviewers, plus those who already reviewed (GitHub drops a
  # reviewer from the request list once they submit a review). Bots and the PR author are never eligible.
  # GitHub only lets collaborators be requested as reviewers, but anyone can submit a review on a public repo, so review
  # authors only count if they are collaborators too.
  reviewers="$({ jq -c '.requested_reviewers[] | {login, type, association: "COLLABORATOR"}' <<<"$pr_json"
                 gh api --paginate "repos/$REPO/pulls/$PR/reviews" \
                   --jq '.[] | {login: .user.login, type: .user.type, association: .author_association}'; } \
    | jq -sc --arg author "$(jq -r .user.login <<<"$pr_json")" --argjson trusted "$TRUSTED" \
        '[.[] | select(.type == "User" and .login != $author and (.association as $a | $trusted | index($a))) | .login] | unique')"
  # Solo mode (repository variable PR_QUIZ_ALLOW_AUTHOR=true): a single maintainer can't be requested as a reviewer on PRs
  # opened with their own account (for example by an agent), so the author may answer too. Anyone with write access can
  # set the variable, so the author must also be a repository admin (who could bypass the gate anyway). Never a bot.
  if [[ "${ALLOW_AUTHOR:-}" == "true" && "$(jq -r .user.type <<<"$pr_json")" == "User" ]]; then
    author="$(jq -r .user.login <<<"$pr_json")"
    if [[ "$(gh api "repos/$REPO/collaborators/$author/permission" --jq .permission 2>/dev/null || true)" == "admin" ]]; then
      reviewers="$(jq -c --arg a "$author" '. + [$a] | unique' <<<"$reviewers")"
    fi
  fi
  # The check belongs to the commit, not the PR, so another open PR with the same head would share (and overwrite) it.
  others="$(gh api "repos/$REPO/commits/$head/pulls" \
    --jq "[.[] | select(.state == \"open\" and .head.sha == \"$head\" and .number != $PR) | \"#\\(.number)\"] | join(\", \")")"
  if [[ -n "$others" ]]; then
    stop "❌ Commit \`${head:0:8}\` is also the head of $others, and the \`$CHECK_NAME\` check belongs to the commit. Close the other PR first."
  fi
}

verify_payload() { # $1 payload file -> validation errors for this PR and head (empty when fine)
  local errors
  errors="$(validation_errors "$1" public 2>&1 || echo "the payload is not valid JSON")"
  if [[ -z "$errors" && "$(jq -r .pr "$1")" != "$PR" ]]; then errors="the quiz was built for another PR"; fi
  if [[ -z "$errors" && "$(jq -r .head_sha "$1")" != "$head" ]]; then
    errors="the quiz covers commit $(jq -r '.head_sha[0:8]' "$1"), but the PR head is ${head:0:8}"
  fi
  printf '%s' "$errors"
}

key_works() { # $1 payload file, $2 key file, $3 question count: the answer key decrypts and belongs to this PR and commit
  (cmd_check_answers "$1" "$(printf "%${3}s" | tr " " A)" "$2" >/dev/null 2>&1)
}

answer_url() { echo "${GITHUB_SERVER_URL:-https://github.com}/$REPO/actions/workflows/pr-quiz.yml"; }

update_check() { # $1 public spec file, $2 state JSON {quiz, details_url, results: [{by, passed}]}, $3 payload (base64)
  local summary text left title passed_by
  summary="$(jq -r -L "$DIR" -f "$DIR/render-markdown.jq" "$1")"
  text="$MARKER$3 -->"$'\n'"$STATE_MARKER$(jq -c . <<<"$2") -->"
  passed_by="$(jq -r '[.results[] | select(.passed) | "@\(.by)"] | first // empty' <<<"$2")"
  left="$(jq -c --argjson s "$2" --argjson max "$MAX_ATTEMPTS" \
    'map(. as $l | {login: $l, used: ([$s.results[] | select(.by == $l)] | length)}) | map(select(.used < $max))' <<<"$reviewers")"
  if [[ -n "$passed_by" ]]; then
    upsert_check "$head" '{"status":"completed","conclusion":"success"}' "Quiz passed by $passed_by" "$summary" "$text" "$(jq -r .details_url <<<"$2")"
  elif [[ "$reviewers" == "[]" ]]; then
    upsert_check "$head" '{"status":"in_progress"}' "Waiting for a reviewer to be requested" \
      "> Only reviewers requested on this PR can answer the quiz. Request one from the PR sidebar."$'\n\n'"$summary" "$text" "$(jq -r .details_url <<<"$2")"
  elif [[ "$left" == "[]" ]]; then
    upsert_check "$head" '{"status":"completed","conclusion":"failure"}' "Quiz not passed, no attempts left" \
      "> Every requested reviewer used all $MAX_ATTEMPTS attempts. Publish a new quiz to try again."$'\n\n'"$summary" "$text" "$(jq -r .details_url <<<"$2")"
  else
    title="$(jq -r --argjson max "$MAX_ATTEMPTS" 'if all(.used == 0) then "Waiting for a reviewer to pass the quiz"
      else "Not passed yet (" + (map("@\(.login): \(.used) of \($max) attempts used") | join(", ")) + ")" end' <<<"$left")"
    upsert_check "$head" '{"status":"in_progress"}' "$title" "$summary" "$text" "$(jq -r .details_url <<<"$2")"
  fi
}

cmd_publish() {
  local out="${OUT_DIR:-.}" errors n state
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  [[ "${QUIZ:-}" =~ ^[A-Za-z0-9+/=]+$ ]] || stop "❌ The quiz payload is missing or is not base64. Use publish-quiz.sh."
  load_pr
  openssl base64 -d -A <<<"$QUIZ" >"$tmp/payload.json" 2>/dev/null || true
  errors="$(verify_payload "$tmp/payload.json")"
  [[ -z "$errors" ]] || stop "❌ The quiz can't be published:"$'\n\n'"$errors"
  n="$(jq '.questions | length' "$tmp/payload.json")"
  (umask 077 && printf '%s\n' "${PR_QUIZ_PRIVATE_KEY:-}" >"$tmp/key.pem")
  key_works "$tmp/payload.json" "$tmp/key.pem" "$n" \
    || stop "❌ The answer key can't be decrypted with this repository's private key, or doesn't belong to PR #$PR at \`${head:0:8}\`. Was public.pem rotated? Rebuild the quiz."
  rm -f "$tmp/key.pem"

  # Re-apply the server-side constants: a payload cannot lower the pass mark or raise the attempt limit.
  public_spec "$tmp/payload.json" "$PR" "$head" "$(jq -r .pr_url "$tmp/payload.json")" "$(quiz_id "$(jq -r .ciphertext "$tmp/payload.json")")" >"$tmp/public.json"
  jq -r -f "$DIR/render-html.jq" "$tmp/public.json" >"$out/pr-$PR-summary.html"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "html=$out/pr-$PR-summary.html" >>"$GITHUB_OUTPUT"; fi
  # A new quiz starts with no attempts, even if an earlier quiz on this commit was passed: the latest quiz decides.
  state="$(jq -cn --arg quiz "${GITHUB_RUN_ID:-local}" --arg url "$RUN_URL" '{quiz: $quiz, details_url: $url, results: []}')"
  update_check "$tmp/public.json" "$state" "$QUIZ"
  write_form "$tmp/public.json" "$state" "" '[]'
  note "✅ Quiz published on PR #$PR for commit \`${head:0:8}\`. Reviewers answer it in the quiz comment on the PR, or at $(answer_url)."$'\n\n'"$(jq -r -L "$DIR" -f "$DIR/render-markdown.jq" "$tmp/public.json")"
  echo "PR #$PR quiz published at $head: reviewers=$reviewers"
}

read_answers() { # $1 question count -> sets given_id (quiz ID) and selected (JSON: ticked letters per question) from the event
  local ev="${GITHUB_EVENT_PATH:?}" form
  if [[ -n "${COMMENT_ID:-}" ]]; then
    # Only the quiz comment written by this workflow, on this PR, and only boxes ticked by whoever made this edit (a re-run
    # by someone else would otherwise answer in the editor's name).
    form="$(jq -c --arg bot "$BOT_LOGIN" --arg pr "$PR" '
      (.comment.body // "" | gsub("\r"; "") | split("\n")) as $lines
      | ($lines[0] | capture("^<!-- pr-quiz-form:v1 pr=(?<pr>[0-9]+) quiz=(?<id>[0-9a-z]+) -->$")? // {}) as $h
      | {ok: (.comment.user.login == $bot and $h.pr == $pr), sender: .sender.login, id: ($h.id // ""),
         ticks: [$lines[] | capture("^\\s*[-*] \\[(?<x>[xX])\\] .*<!-- pr-quiz:(?<k>q[1-5]:[A-D]|submit) -->\\s*$")? | .k]}' "$ev")"
    [[ "$(jq -r .ok <<<"$form")" == "true" ]] || { COMMENT_ID=""; stop "❌ That comment is not the quiz comment of PR #$PR."; }
    [[ "$(jq -r .sender <<<"$form")" == "$ACTOR" ]] || { COMMENT_ID=""; stop "❌ Only the person who ticked Submit can submit those answers."; }
    jq -e '.ticks | index("submit")' <<<"$form" >/dev/null || { COMMENT_ID=""; note "Submit is not ticked; nothing to grade."; exit 0; }
    given_id="$(jq -r .id <<<"$form")"
    selected="$(jq -c --argjson n "$1" '.ticks as $t | [range(1; $n + 1) as $i | [$t[] | select(startswith("q\($i):")) | .[3:]] | unique | join("")]' <<<"$form")"
  else
    given_id="$(jq -r '.inputs.quiz_id // "" | ascii_downcase | gsub("\\s"; "")' "$ev")"
    selected="$(jq -c --argjson n "$1" '[.inputs.q1, .inputs.q2, .inputs.q3, .inputs.q4, .inputs.q5]
      | map((. // "-") | ascii_upcase | select(test("^[A-D]$")) // "") as $q
      | if ([.[] | (. // "-") | ascii_upcase] | .[$n:] | all(. == "-")) then $q[:$n] else $q[:$n] + ["extra"] end' "$ev")"
  fi
}

cmd_answer() {
  local check payload state errors id n given result attempts passed who given_id selected bad
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  COMMENT_ID="$(jq -r '.comment.id // empty' "${GITHUB_EVENT_PATH:?}")"
  load_pr
  check="$(latest_check "$head")"
  payload="$(marker_value "$check" "$MARKER")"
  state="$(marker_value "$check" "$STATE_MARKER")"
  if [[ -z "$payload" || -z "$state" ]]; then
    stop "⚠️ PR #$PR has no quiz for its current head commit \`${head:0:8}\`. A new push makes the previous quiz stale; wait for the author to publish a new one. This did not count as an attempt."
  fi
  openssl base64 -d -A <<<"$payload" >"$tmp/payload.json" 2>/dev/null || true
  errors="$(verify_payload "$tmp/payload.json")"
  [[ -z "$errors" ]] || stop "❌ The quiz on the \`$CHECK_NAME\` check can't be graded ($errors). Ask the author to publish a new one."
  id="$(quiz_id "$(jq -r .ciphertext "$tmp/payload.json")")"
  public_spec "$tmp/payload.json" "$PR" "$head" "$(jq -r .pr_url "$tmp/payload.json")" "$id" >"$tmp/public.json"
  n="$(jq '.questions | length' "$tmp/payload.json")"
  read_answers "$n"

  if ! jq -e --arg l "$ACTOR" 'index($l)' <<<"$reviewers" >/dev/null; then
    if [[ "${ALLOW_AUTHOR:-}" == "true" ]]; then who="its requested reviewers and, if a repository admin, its author"; else who="its requested reviewers (not the PR author)"; fi
    refuse "⚠️ @$ACTOR, only $who can answer the quiz on PR #$PR, never bots or agents. Ask the author to request your review, then answer again. This did not count as an attempt." '[]'
  fi
  if jq -e '.results | any(.passed)' <<<"$state" >/dev/null; then
    if [[ -n "$COMMENT_ID" ]]; then write_form "$tmp/public.json" "$state" "✅ This quiz has already been passed." '[]'; fi
    note "✅ The quiz on PR #$PR has already been passed."; return 0
  fi
  if [[ "$given_id" != "$id" ]]; then
    refuse "⚠️ @$ACTOR, those answers are for another version of the quiz on PR #$PR: it was replaced or the quiz ID was mistyped. Re-read the summary and the questions shown now, then answer again. This did not count as an attempt." '[]'
  fi
  attempts="$(jq --arg l "$ACTOR" '[.results[] | select(.by == $l)] | length' <<<"$state")"
  if (( attempts >= MAX_ATTEMPTS )); then
    refuse "⛔ @$ACTOR, you have no attempts left for this quiz. Re-read the summary and ask the author to publish a new quiz." '[]'
  fi
  bad="$(jq -r 'to_entries | map(select((.value | length) != 1) | "Q\(.key + 1)") | join(", ")' <<<"$selected")"
  if [[ -n "$bad" ]]; then
    if [[ -n "$COMMENT_ID" ]]; then
      refuse "⚠️ @$ACTOR, tick exactly one box for each question ($bad), then tick Submit again. This did not count as an attempt." "$selected"
    fi
    refuse "⚠️ This quiz has $n questions: choose an answer for Q1 to Q$n and leave the other questions at \`-\`. This did not count as an attempt." '[]'
  fi
  given="$(jq -r 'join("")' <<<"$selected")"

  (umask 077 && printf '%s\n' "${PR_QUIZ_PRIVATE_KEY:-}" >"$tmp/key.pem")
  if ! result="$(cmd_check_answers "$tmp/payload.json" "$given" "$tmp/key.pem" 2>/dev/null)"; then
    rm -f "$tmp/key.pem"
    upsert_check "$head" '{"status":"completed","conclusion":"failure"}' "Quiz can't be graded" \
      "> The answer key could not be decrypted (for example after a key rotation). Publish a new quiz."$'\n\n'"$(jq -r -L "$DIR" -f "$DIR/render-markdown.jq" "$tmp/public.json")" \
      "$(jq -r '.output.text' <<<"$check")" "$(jq -r .details_url <<<"$state")"
    stop "❌ This quiz can't be graded: its answer key could not be decrypted. Ask the author to publish a new quiz. This did not count as an attempt."
  fi
  rm -f "$tmp/key.pem"
  passed="$(jq -r .passed <<<"$result")"
  state="$(jq -c --arg l "$ACTOR" --argjson p "$passed" '.results += [{by: $l, passed: $p}]' <<<"$state")"
  update_check "$tmp/public.json" "$state" "$payload"
  echo "PR #$PR quiz $(jq -r .quiz <<<"$state") at $head: reviewers=$reviewers results=$(jq -c .results <<<"$state")"
  if [[ "$passed" == "true" ]]; then
    write_form "$tmp/public.json" "$state" "✅ @$ACTOR passed the quiz. The \`$CHECK_NAME\` check is green." '[]'
    note "✅ @$ACTOR passed the quiz on PR #$PR ($(jq -r .score <<<"$result")%). The \`$CHECK_NAME\` check is green."
  else
    # Only pass/fail is reported, and the boxes are cleared: a per-attempt score or per-question result would tell the
    # reviewer which guesses were right.
    result="❌ @$ACTOR, not passed. The pass mark is ${PASS_MARK}%. Attempts left: $((MAX_ATTEMPTS - attempts - 1)). Re-read the summary and try again."
    write_form "$tmp/public.json" "$state" "$result" '[]'
    COMMENT_ID=""
    stop "$result"
  fi
}

case "${1:-}" in
  validate) shift; cmd_validate "$@" ;;
  build) shift; cmd_build "$@" ;;
  check-answers) shift; cmd_check_answers "$@" ;;
  publish) cmd_publish ;;
  answer) cmd_answer ;;
  *) sed -n '2,11p' "$0" >&2; exit 2 ;;
esac
