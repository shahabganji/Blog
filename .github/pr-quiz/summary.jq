# Shared by render-markdown.jq (the pr-quiz check) and render-comment.jq (the quiz comment on the PR):
# the summary part of a public quiz spec as Markdown. Load with: jq -L <this directory> 'include "summary"; ...'
def section($title; $body): if ($body // "") == "" then "" else "### \($title)\n\n\($body)\n\n" end;
def bullets($items): ($items // []) | map("- \(.)") | join("\n");
def letter($i): "ABCD"[$i:$i+1];
def cell: tostring | gsub("\\|"; "\\|") | gsub("\n"; " ");
def oneline: tostring | gsub("\\s*\n\\s*"; " ");
def answer_url: .pr_url | sub("/pull/[0-9]+$"; "/actions/workflows/pr-quiz.yml");
def who_can_answer: if .allow_author then "Only reviewers requested on this PR, and the PR author if a repository admin, can answer (not bots). "
                    else "Only reviewers requested on this PR can answer (not the author or bots). " end;

def summary_md:
  "## 🧭 \(.title)\n\n"
  + "> \(.tldr)\n\n"
  + section("Why"; .why)
  + section("Intent"; .intent)
  + section("What changed"; (.what // []) | map("- **\(.title)**: \(.detail)") | join("\n"))
  + section("Key decisions"; if (.decisions // []) == [] then "" else
      "| Decision | Reason |\n|---|---|\n" + ((.decisions) | map("| \(.decision | cell) | \(.reason | cell) |") | join("\n")) end)
  + section("Risks and follow-ups"; bullets(.risks))
  + section("Out of scope"; bullets(.out_of_scope))
  + section("Review discussion"; (.review_discussion // []) | map("- **\(.source)**: \(.topic) → \(.outcome)") | join("\n"));
