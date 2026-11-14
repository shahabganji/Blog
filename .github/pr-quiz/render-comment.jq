# Renders the quiz comment on the PR: the summary, then each question as checkboxes and a Submit box.
# Ticking a box edits the comment, which triggers pr-quiz-comment.yml (issue_comment: edited); quiz.sh reads the ticked boxes from the
# hidden markers at the end of each line. The comment never contains the answers.
# Input: the public quiz spec plus .form = {open: bool, notice: Markdown}. Every box is rendered unticked.
# Usage: jq -r -L <this directory> -f render-comment.jq
include "summary";

.form as $f
| "<!-- pr-quiz-form:v1 pr=\(.pr) quiz=\(.quiz_id) -->\n"
+ "<details><summary><b>PR quiz: what this PR is about</b> (read before answering)</summary>\n\n"
+ summary_md
+ "</details>\n\n"
+ "### 📝 Comprehension quiz: \(.title | oneline)\n\n"
+ (if ($f.notice // "") == "" then "" else "\($f.notice)\n\n" end)
+ ([.questions | to_entries[] | .key as $i |
    "**Q\($i + 1). \(.value.question | oneline)**\n\n"
    + (.value.options | to_entries | map(letter(.key) as $l |
        if $f.open then "- [ ] \($l)) \(.value | oneline) <!-- pr-quiz:q\($i + 1):\($l) -->"
        else "- \($l)) \(.value | oneline)" end) | join("\n"))
  ] | join("\n\n"))
+ (if $f.open then "\n\n- [ ] **Submit my answers** <!-- pr-quiz:submit -->\n\n"
     + "<sub>Tick one box per question, then tick **Submit my answers**; the result appears here a few seconds later. "
     + who_can_answer + "Each gets \(.max_attempts) attempts; the `pr-quiz` check passes at \(.pass_mark)%.</sub>\n"
   else "\n" end)
+ "\n<sub>Quiz `\(.quiz_id)` for commit \(.head_sha[0:8]). A new push makes it stale until a new quiz is published.</sub>\n"
