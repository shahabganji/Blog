# Renders the public quiz spec (answers stripped) as the Markdown body of the PR quiz comment.
# Usage: jq -r -f render-markdown.jq public-spec.json
def section($title; $body): if ($body // "") == "" then "" else "### \($title)\n\n\($body)\n\n" end;
def bullets($items): ($items // []) | map("- \(.)") | join("\n");
def letter($i): "ABCD"[$i:$i+1];
def cell: tostring | gsub("\\|"; "\\|") | gsub("\n"; " ");

"## 🧭 \(.title)\n\n"
+ "> \(.tldr)\n\n"
+ section("Why"; .why)
+ section("Intent"; .intent)
+ section("What changed"; (.what // []) | map("- **\(.title)**: \(.detail)") | join("\n"))
+ section("Key decisions"; if (.decisions // []) == [] then "" else
    "| Decision | Reason |\n|---|---|\n" + ((.decisions) | map("| \(.decision | cell) | \(.reason | cell) |") | join("\n")) end)
+ section("Risks and follow-ups"; bullets(.risks))
+ section("Out of scope"; bullets(.out_of_scope))
+ section("Review discussion"; (.review_discussion // []) | map("- **\(.source)**: \(.topic) → \(.outcome)") | join("\n"))
+ "### 📝 Comprehension quiz (\(.questions | length) question\(if (.questions | length) == 1 then "" else "s" end), pass mark \(.pass_mark)%)\n\n"
+ ([.questions | to_entries[] |
    "**\(.key + 1). \(.value.question)**\n\n"
    + (.value.options | to_entries | map("- \(letter(.key))) \(.value)") | join("\n"))
  ] | join("\n\n"))
+ "\n\n---\n"
+ "Answer with a PR comment containing one letter per question, in order, for example `/quiz "
+ ([range(0; .questions | length)] | map(letter(. % 4)) | join(" "))
+ "`. Only reviewers requested on this PR can answer (not the author or bots). Each reviewer gets \(.max_attempts) attempts. The `pr-quiz` check passes at \(.pass_mark)% or higher. A clickable version of this page is attached to the `pr-quiz` check (**Details**).\n"
+ "_Summary for commit \(.head_sha[0:8]). It is regenerated if the PR changes._\n"
