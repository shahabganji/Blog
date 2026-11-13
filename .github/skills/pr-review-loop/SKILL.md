---
name: pr-review-loop
description: Drive a pull request to "ready to merge" in a loop. Wait for the Copilot and Gitar reviews, fix or answer every review comment, resolve threads, keep checks green, then publish an intent-focused summary (PR comment + HTML) with a short comprehension quiz that a reviewer must pass (pr-quiz check). Use when asked to create a PR and see it through review, to address bot review comments on a PR, or to publish a PR summary/quiz.
---

# PR review loop

You own a pull request until it is ready for a human to merge. You **never merge** it yourself.

Helper scripts (run from the repository root):

| Script | Purpose |
|---|---|
| `.github/skills/pr-review-loop/scripts/pr-state.sh <pr> [--wait]` | JSON snapshot: head SHA, Copilot/Gitar review status, `missing_reviews`, pending/failing checks, unresolved threads (with `thread_id` and `first_comment_id`), latest bot comments, `ready_for_quiz`. `--wait` blocks until the PR has settled for its head commit. Set `REQUIRED_BOTS` (default `"copilot gitar"`) if a repository has only one of them. |
| `.github/skills/pr-review-loop/scripts/reply-thread.sh <pr> <first_comment_id> <body-file> [--resolve <thread_id>]` | Reply to a review thread (body from a file, never inline) and optionally resolve it. |
| `.github/skills/pr-review-loop/scripts/publish-quiz.sh <pr> <quiz.json> [--dry-run]` | Post the summary + quiz comment and write the HTML summary. |

The quiz engine, renderers and grading workflow are documented in `.github/pr-quiz/README.md`.

## 1. Open the PR

1. Work on a feature branch. PRs target the branch the user names, otherwise the repository's deploy branch (`shahab` here; `master` only mirrors upstream).
2. Build and run the relevant tests before the first push.
3. Push and open the PR with `gh pr create`. Describe the why and the intent, not a file list.

## 2. Loop until settled

Repeat, with at most **10 iterations**. If you hit the cap, stop and report what is still open.

1. `pr-state.sh <pr> --wait > state.json` (session workspace, not the repo). This waits for Copilot's review run, the `Gitar` check and every other check on the head commit.
2. If `failing_checks` is not empty, open each failing run (`gh run view <id> --log-failed`), fix the cause, and continue at step 5.
3. Read `unresolved_threads` and the latest Gitar / Copilot entries in `bot_comments`. Triage every thread as described in section 3.
4. Apply all fixes for this round together. Build and test.
5. Commit with a message that explains the change. Push once per round; every push triggers a new Copilot review, so don't push one commit per comment.
6. After pushing, reply to the threads you fixed (`Fixed in <short-sha>: <one line on what changed>`) and resolve them.
7. Go back to step 1.

The loop is done when `ready_for_quiz` is `true`: no unresolved threads, no pending or failing checks (ignoring `pr-quiz`), and Copilot and Gitar have finished reviewing the head commit.

If `missing_reviews` is not empty after `--wait` returns, a bot never reviewed the head commit. For Copilot, re-request the review (`gh api repos/<owner>/<repo>/pulls/<pr>/requested_reviewers -f "reviewers[]=copilot-pull-request-reviewer[bot]"`) and wait again. For Gitar, or if Copilot still does not review, ask the user.

## 3. Triage rules for review comments

For every unresolved thread, decide one of the following and act:

| Verdict | Action |
|---|---|
| **Valid**: a real bug, risk or clear improvement within the PR's scope | Fix it. After the push, reply `Fixed in <sha>` with a short explanation and resolve. |
| **Already handled**: the current code already addresses it, or the thread is outdated | Reply with evidence (commit, file and line, command output) and resolve. |
| **Not valid**: wrong, a misunderstanding, or contradicts a deliberate decision | Reply politely with the reasoning and evidence. Resolve if the author is a bot (Copilot, Gitar). For humans, leave the thread open for them. |
| **Out of scope**: valid but unrelated to the PR's intent | Reply that it is out of scope, suggest a follow-up issue (create it if the user asked for that), and resolve if from a bot. |
| **Needs a decision**: trade-offs, product or security choices, anything you are unsure about | Do not guess. Ask the user (ask_user) with the options and your recommendation, then continue with their answer. |

Rules:
- Read the whole thread, including earlier replies, before acting. Don't reply twice with the same content.
- Write reply bodies to a file and pass the path to `reply-thread.sh`, so Markdown and backticks never go through the shell.
- Comments from the user or other humans outrank bot suggestions. Never resolve a human's thread you disagree with.
- If a bot repeats a claim you already refuted, reply once with fresh evidence (for example the CI output) and resolve.
- Gitar also posts a summary comment (`bot_comments`). Treat findings listed there like threads, even when they have no inline thread.

## 4. Safety rules

- Never merge, close, force-push, rewrite published history, or bypass rulesets.
- Never weaken a gate to make it pass: no edits to `.github/workflows/pr-quiz.yml`, `.github/workflows/copilot-review-gate.yml`, `.github/pr-quiz/**` or rulesets unless that is the PR's explicit purpose and the user asked for it.
- Never answer the quiz, and never write the answers anywhere except the private `quiz.json` in the session workspace. Only a human reviewer requested on the PR may answer it. Never request a reviewer yourself just to get the quiz answered; ask the user who should review.
- Never commit secrets, `appsettings.*` files with real values, or the private quiz spec.
- Never disable or skip tests or checks to get to green.

## 5. Write the summary and quiz

When `ready_for_quiz` is `true`, write `quiz.json` in the session workspace (see `quiz-spec.example.json` for the shape):

| Field | Content |
|---|---|
| `title` | The PR's outcome in plain words. |
| `tldr` | One sentence a busy reviewer can read. |
| `why` | The problem or motivation. What was wrong or missing before? |
| `intent` | What the change is meant to achieve and how to tell that it worked. |
| `what` | 2–6 items `{title, detail}` describing behaviour or capability changes, **not** files or code. |
| `decisions` | `{decision, reason}` for the important choices, including rejected alternatives. |
| `risks` | Known risks, limitations and follow-ups. |
| `out_of_scope` | What the PR deliberately does not do. |
| `review_discussion` | `{source, topic, outcome}` for each meaningful review thread, e.g. a Copilot finding that was fixed or a Gitar claim that was refuted. |
| `questions` | 2–5 multiple-choice questions, `{question, options[4], answer}` with `answer` one of `A`–`D`. |

Writing the questions:
- **How many**: one question per distinct idea or decision in the PR, with a minimum of 2 (a single question can be guessed). Small PRs get 2; a PR with several independent concerns gets up to 5.
- **More than 5 needed?** Don't publish a quiz. That many ideas means the PR does too much. Post a PR comment proposing how to split it (which changes go into which PR, and in what order) and stop.
- Test the **why, the intent and the consequences** ("What would happen if…", "Why was X chosen over Y?"), not trivia such as file names, line counts or exact identifiers.
- Every question must be answerable from the summary alone.
- Distractors must be plausible to someone who skimmed the PR: common misconceptions or rejected alternatives. Avoid "all of the above" and joke options.
- Vary the position of the correct answer; don't put it in the same slot every time.

Then:
1. `publish-quiz.sh <pr> quiz.json --dry-run`, open the HTML and proofread it.
2. `publish-quiz.sh <pr> quiz.json`. This posts the comment (older quiz comments are minimized) and the `pr-quiz` workflow sets the `pr-quiz` check to pending.
3. If the script warns that the gate isn't active yet, tell the user to run `.github/pr-quiz/setup.sh --activate`.

Any new push makes the quiz stale: the new head has no `pr-quiz` check. If you push after publishing (for example to fix a late review comment), run the loop again and publish a fresh quiz.

## 6. Report back

End with a short report:
- the PR link;
- the number of review rounds;
- the threads fixed, refuted or escalated, with links;
- the path to the HTML summary;
- that the PR now waits for a requested human reviewer to pass the quiz (`/quiz …` comment) and to merge it. If no human reviewer is requested, say so: the PR author can't answer their own quiz.
