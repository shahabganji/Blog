# PR comprehension quiz

A merge gate that checks a reviewer understood **why** a PR exists and **what** it is meant to achieve before it is merged into `shahab`.

## How it works

```
agent (pr-review-loop skill)                     pr-quiz.yml (runs from the default branch)
──────────────────────────────                   ──────────────────────────────────────────
reviews settled, all threads resolved
writes quiz.json (summary + ≤5 questions)
quiz.sh build ─ encrypts answers with public.pem
posts the summary + quiz comment ───────────────▶ publish: validate, render HTML (artifact + job summary),
                                                   set check "pr-quiz" = pending on the PR head
reviewer reads the summary, comments "/quiz B C" ─▶ grade: decrypt answers (environment secret), score,
                                                   reply with the score, set "pr-quiz" = success (≥ 90%)
                                                   or failure (3 attempts used)
```

- The comment contains the summary and questions in Markdown. A hidden `<!-- pr-quiz:v1 … -->` payload holds the same data plus the answer key, encrypted with RSA-OAEP. The key is bound to the PR number and head commit, so it cannot be copied to another PR.
- The HTML summary (`pr-<n>-summary.html`) is written locally by the skill, and uploaded as an artifact of the `publish` run (linked from the `pr-quiz` check's **Details**). It includes a clickable version of the quiz that builds the `/quiz …` comment for you.
- Answer format: one letter per question, in order: `/quiz B C A`, `/quiz bca` and `/quiz 1B 2C 3A` all work. Malformed answers or the wrong count don't use an attempt.
- Pass mark is 90% and there are 3 attempts per quiz. The constants live in `quiz.sh`; the workflow re-applies them, so a quiz comment cannot change them. With up to 5 questions, 90% means every answer must be right.
- The reply only gives the score, not which answers were wrong. After a pass, the answer comment is minimized.
- A new push changes the head commit, which has no `pr-quiz` check yet. The PR is blocked again until a fresh quiz is published and passed.

## Files

| File | Purpose |
|---|---|
| `quiz.sh` | Engine: validate / build (local) and publish / grade (CI). |
| `render-markdown.jq`, `render-html.jq` | Render the public spec (no answers) as the PR comment and the HTML page. All text is HTML-escaped. |
| `public.pem` | Public key used to encrypt answer keys. Safe to commit. |
| `setup.sh` | One-time setup (see below). |
| `../workflows/pr-quiz.yml` | The `publish` and `grade` jobs. |
| `../skills/pr-review-loop/` | The Copilot skill that drives a PR through review and writes the quiz. |

## Setup

```bash
.github/pr-quiz/setup.sh              # pr-quiz environment (deploy branch only) + keypair + PR_QUIZ_PRIVATE_KEY secret
.github/pr-quiz/setup.sh --activate   # also: default branch -> shahab, ruleset "shahab: PR quiz" requiring the pr-quiz check
.github/pr-quiz/setup.sh --rotate     # new keypair; commit the new public.pem (quizzes already posted can no longer be graded)
```

The private key is generated in a temp directory, uploaded straight to the environment secret and then deleted. It never touches the repository.

### Why `--activate` changes the default branch

`/quiz` answers are PR comments, and `issue_comment` workflows only run from the **default branch**. With `master` as default (it only mirrors upstream), the grader would never run. Making `shahab` the default branch also means:

- New PRs target `shahab` by default.
- Scheduled workflows (for example CodeQL in `codeql.yml`) run against `shahab`.
- Upstream syncing of `master` is unaffected.

Running the grader from the default branch is also what makes it trustworthy: a PR (or an AI agent working on one) cannot change how it is graded, and the `pr-quiz` environment, which holds the private key, can only be used by `shahab`.

Activate only after this workflow is merged into `shahab`. Otherwise the required `pr-quiz` check can't be reported and every PR is blocked.

## Trust model and limits

This is a **comprehension gate, not a security control**.

- The public key is public, so any collaborator can post a quiz with answers they know. Only quiz comments from OWNER/MEMBER/COLLABORATOR count.
- Anyone with write access can answer, including the PR author. That suits a single-maintainer repository.
- Any workflow in this repository that has `checks: write` could create a check named `pr-quiz` (they all share the GitHub Actions app id that the ruleset matches).
- Answers are visible in the answer comment until it is minimized after a pass. Each new quiz has new questions.
- Repository admins can bypass the ruleset.

## Local testing

```bash
export QUIZ_PUBLIC_KEY=/tmp/test-pub.pem   # throwaway keypair, generated with openssl
.github/pr-quiz/quiz.sh validate .github/skills/pr-review-loop/quiz-spec.example.json
.github/pr-quiz/quiz.sh build .github/skills/pr-review-loop/quiz-spec.example.json 1 "$(git rev-parse HEAD)" https://example/pr/1 /tmp/s.html
.github/pr-quiz/quiz.sh parse-answers "/quiz 1B 2C"
.github/pr-quiz/quiz.sh check-answers payload.json BC /tmp/test-key.pem
```
