# Renders the public quiz spec (answers stripped) as the Markdown summary of the pr-quiz check.
# Usage: jq -r -L <this directory> -f render-markdown.jq public-spec.json
include "summary";

summary_md
+ "### 📝 Comprehension quiz (\(.questions | length) question\(if (.questions | length) == 1 then "" else "s" end), pass mark \(.pass_mark)%)\n\n"
+ "Quiz ID: `\(.quiz_id)`\n\n"
+ ([.questions | to_entries[] |
    "**Q\(.key + 1). \(.value.question)**\n\n"
    + (.value.options | to_entries | map("- \(letter(.key))) \(.value)") | join("\n"))
  ] | join("\n\n"))
+ "\n\n---\n"
+ "**How to answer:** in the **PR quiz** comment on [the pull request](\(.pr_url)), tick one box per question, then tick **Submit my answers**. "
+ "The comment shows the result a few seconds later. "
+ "Or use the [PR quiz: answer](\(answer_url)) form: **Run workflow** with PR `\(.pr)`, quiz ID `\(.quiz_id)` and one letter for each of Q1 to Q\(.questions | length). "
+ who_can_answer
+ "Each reviewer gets \(.max_attempts) attempts. The `pr-quiz` check passes at \(.pass_mark)% or higher.\n\n"
+ "_Summary for commit \(.head_sha[0:8]). A new push makes it stale until a new quiz is published._\n"
