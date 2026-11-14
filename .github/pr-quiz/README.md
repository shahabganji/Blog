# PR comprehension quiz

A merge gate that checks a reviewer understood **why** a PR exists and **what** it is meant to achieve before it is merged into `shahab`.

## How it works

The quiz is posted as a comment on the PR, with a checkbox for each option. Reviewers tick their answers and a **Submit** box, and a workflow grades them. The result is kept on the PR's `pr-quiz` check, which is what the ruleset requires. A GitHub Actions form is the fallback.

```
agent (pr-review-loop skill)                        GitHub Actions (workflows run from the default branch)
──────────────────────────────                      ───────────────────────────────────────────────────────
reviews settled, all threads resolved
writes quiz.json (summary + 2–5 questions)
quiz.sh build ─ encrypts answers with public.pem
publish-quiz.sh dispatches the payload ───────────▶ "PR quiz: publish": validate, set check "pr-quiz" = pending
                                                    with the summary + quiz as its Markdown, post the quiz comment
                                                    on the PR, attach the HTML page
requested reviewer reads the quiz comment,
ticks one box per question, ticks Submit ─────────▶ "PR quiz: answer in comment" (issue_comment edited): grade,
                                                    record the attempt in the check, set "pr-quiz" = success
                                                    (≥ 90%) or failure (attempts used up), rewrite the comment
(fallback: Actions ▸ "PR quiz: answer" ▸ Run
workflow with PR, quiz ID, Q1–Q5) ────────────────▶ "PR quiz: answer": the same grading
```

### For the reviewer

1. On the PR, find the **PR quiz** comment from `github-actions`. Expand *what this PR is about* and read the summary.
2. Tick one box per question, then tick **Submit my answers**.
3. A few seconds later the comment shows the result: passed (the boxes go away and the `pr-quiz` check turns green), not passed (the boxes are cleared and the attempts left are shown), or why the answer was refused (no attempt used). Reload the page if it doesn't update.

The same summary and questions are on the `pr-quiz` check (merge box → **Details**), and the publish run has them as an HTML page (`pr-<n>-summary.html`). If ticking boxes doesn't suit you, use the fallback form: **Actions → PR quiz: answer → Run workflow** with the PR number, the **quiz ID** shown on the check, and a letter for each question (leave the questions the quiz doesn't have at `-`).

Only **reviewers requested on the PR** can answer: users in the PR's *Reviewers* list, including those who have already submitted a review (only if they are collaborators, since anyone can review a public PR). GitHub records who edited the comment (or started the form run), so nobody can answer for someone else. Ticking boxes in someone else's comment needs write access, which requested reviewers have. Runs by the PR author (unless solo mode is on and the author is a repository admin, see the trust model), bots or apps (Copilot included) are refused and don't use an attempt. The author requests a reviewer from the PR sidebar. Running a workflow needs write access, which requested reviewers have.

### Details

- The check's summary is the rendered quiz. Its text holds two hidden markers: the published payload (`<!-- pr-quiz:v1 … -->`: the same data plus the answer key, encrypted with RSA-OAEP and bound to the PR number and head commit) and the attempts so far (`<!-- pr-quiz-state:v1 … -->`).
- The answers are read from the run's event file, not passed through `env`, so they never appear in the log or the run summary.
- The quiz comment is only the answer form. It is rewritten from the check after every publish and answer, and only which boxes are ticked is read from it; anything else edited into it is ignored or overwritten. It holds the PR number and quiz ID in a hidden first line, and each box ends with a hidden `<!-- pr-quiz:q<n>:<letter> -->` marker. A run only grades the comment written by `github-actions[bot]` on that PR, with **Submit** ticked, in the name of the person whose edit triggered it (a re-run by someone else is refused).
- Ticking one box per question isn't enforced by GitHub (they are checkboxes, not radio buttons). A submit with no box or several boxes on a question is refused without using an attempt, and the ticks are kept so they can be fixed.
- Every comment edit in the repository starts a "PR quiz: answer in comment" run, but it is skipped unless it is the quiz comment with Submit ticked. Edits made by the workflow itself don't trigger runs.
- Pass mark is 90% and each reviewer gets 3 attempts per quiz. One reviewer passing is enough. The check only fails when every requested reviewer has used up their attempts.
- Quizzes have 2–5 questions, because a single question can be guessed. The fallback form has 5 fixed slots (Q1–Q5), because workflow inputs can't change per PR. Answering the wrong number of questions doesn't use an attempt. The constants live in `quiz.sh` and are re-applied on every run, so a payload cannot change them. With up to 5 questions, 90% means every answer must be right.
- A failed attempt is only reported as "not passed", without a score or which questions were wrong, and the boxes are cleared, so results can't be used to narrow down guesses.
- Publishing checks that the payload is valid, belongs to the PR's current head commit and decrypts with the private key. A bad payload is refused and the check is left as it was.
- Every build of a quiz has a 6-character quiz ID, derived from its encrypted answer key. The quiz comment carries it, and the fallback form asks for it; an answer with another ID (the quiz was replaced after the reviewer read it, or while the run was queued) is refused without using an attempt, so it is never graded against a quiz the reviewer didn't see.
- Publishing again replaces the quiz and resets the attempts, even after a pass: the latest quiz decides. A completed check can't go back to pending, so a new check run is created; the newest run is the one that counts.
- A new push changes the head commit, which has no `pr-quiz` check yet. The PR is blocked again until a fresh quiz is published and passed. Answers for the old commit are refused.
- If the answer key can't be decrypted when grading (for example after `setup.sh --rotate`), the check fails. Publish a new quiz to recover.
- The `pr-quiz` check belongs to the head commit, not the PR. If another open PR has the same head commit, publishing and answering are refused until that PR is closed.
- The quiz workflows share a concurrency group per PR, so the check and the comment are never updated by two runs at once. If several reviewers submit at the same moment, GitHub may cancel a queued run. A cancelled run doesn't use an attempt; tick Submit (or run the form) again.

## Files

| File | Purpose |
|---|---|
| `quiz.sh` | Engine: validate / build (local), publish / answer (CI). |
| `summary.jq`, `render-markdown.jq`, `render-comment.jq`, `render-html.jq` | Render the public spec (no answers): the shared summary, the check's Markdown, the quiz comment with its checkboxes, and the HTML page (all text HTML-escaped). |
| `public.pem` | Public key used to encrypt answer keys. Safe to commit. |
| `setup.sh` | One-time setup (see below). |
| `../workflows/pr-quiz-publish.yml` | "PR quiz: publish": runs `quiz.sh publish` for the skill. |
| `../workflows/pr-quiz-comment.yml` | "PR quiz: answer in comment": runs `quiz.sh answer` when Submit is ticked in the quiz comment. |
| `../workflows/pr-quiz.yml` | "PR quiz: answer": the fallback answer form, runs `quiz.sh answer`. |
| `../skills/pr-review-loop/` | The Copilot skill that drives a PR through review and writes the quiz. |

## Setup

```bash
.github/pr-quiz/setup.sh              # pr-quiz environment (deploy branch only) + keypair + PR_QUIZ_PRIVATE_KEY secret
.github/pr-quiz/setup.sh --activate   # also: default branch -> shahab, ruleset "shahab: PR quiz" requiring the pr-quiz check
.github/pr-quiz/setup.sh --solo       # also: the PR author may answer (repository variable PR_QUIZ_ALLOW_AUTHOR=true)
.github/pr-quiz/setup.sh --rotate     # new keypair; commit the new public.pem (quizzes already posted can no longer be graded)
```

The private key is generated in a temp directory, uploaded straight to the environment secret and then deleted. It never touches the repository.

### Why `--activate` changes the default branch

The publish and answer forms are `workflow_dispatch` workflows, and GitHub only lists and dispatches those when they exist on the **default branch**. With `master` as default (it only mirrors upstream), the quiz could never be published or answered. Making `shahab` the default branch also means:

- New PRs target `shahab` by default.
- Scheduled workflows (for example CodeQL in `codeql.yml`) run against `shahab`.
- Upstream syncing of `master` is unaffected.

The forms run from `shahab`, and the `pr-quiz` environment, which holds the private key, only accepts `shahab`. A run on any other branch can't read the key, so a PR (or an AI agent working on one) cannot change how it is graded.

Activate only after this workflow is merged into `shahab`. Otherwise the required `pr-quiz` check can't be reported and every PR is blocked.

## Trust model and limits

This is a **comprehension gate, not a security control**.

- The public key is public, so anyone who can run the publish workflow (write access) can publish a quiz with answers they know.
- Only requested reviewers who are users (not bots) and not the PR author can answer. GitHub can't tell whether a *person's* token is being used by an agent. If a reviewer lets an agent run workflows as them, the agent could answer. Agents that work with the author's token are excluded as the author.
- In a single-maintainer repository, the maintainer can't be requested as a reviewer on their own PRs (GitHub doesn't allow requesting a review from the PR author), and agents working locally open PRs with the maintainer's account. **Solo mode** (`setup.sh --solo`, i.e. the repository variable `PR_QUIZ_ALLOW_AUTHOR=true`) lets the PR author answer as well, but only if the author is a repository admin (a user, not a bot). It is off by default. Anyone with write access can change repository variables, so the variable alone is not a trust boundary: the admin check is. That adds no new hole, because admins can already bypass the gate, and when the agent uses the maintainer's token it can't do more than the maintainer could. In a team, solo mode lets admins pass the quiz on their own PRs, so leave it off unless that's acceptable. Without solo mode: request a review from another collaborator, or merge with the admin bypass. PRs opened by the Copilot coding agent are authored by a bot, so the maintainer can be their reviewer.
- Any workflow in this repository that has `checks: write` could create a check named `pr-quiz` (they all share the GitHub Actions app id that the ruleset matches).
- The answers a reviewer picks are not shown in the run's log or summary. Each new quiz has new questions.
- Repository admins can bypass the ruleset.

## Local testing

```bash
export QUIZ_PUBLIC_KEY=/tmp/test-pub.pem   # throwaway keypair, generated with openssl
.github/pr-quiz/quiz.sh validate .github/skills/pr-review-loop/quiz-spec.example.json
.github/pr-quiz/quiz.sh build .github/skills/pr-review-loop/quiz-spec.example.json 1 "$(git rev-parse HEAD)" https://github.com/o/r/pull/1 /tmp
# -> prints the payload; writes /tmp/pr-1-quiz.md (check summary) and /tmp/pr-1-summary.html
.github/pr-quiz/quiz.sh check-answers payload.json BC /tmp/test-key.pem
```
