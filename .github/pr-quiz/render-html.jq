# Renders the public quiz spec (answers stripped) as a self-contained HTML page.
# The page never contains the answers. Reviewers can tick options while reading; they submit them with the "PR quiz: answer" form.
# Usage: jq -r -f render-html.jq public-spec.json > summary.html
def e: tostring | @html;
def letter($i): "ABCD"[$i:$i+1];
def list($items): if ($items // []) == [] then "" else "<ul>" + (($items) | map("<li>\(e)</li>") | join("")) + "</ul>" end;
def card($icon; $title; $body): if ($body // "") == "" then "" else
  "<section class=\"card\"><h2><span class=\"icon\">\($icon)</span>\($title | e)</h2>\($body)</section>" end;
def answer_url: .pr_url | sub("/pull/[0-9]+$"; "/actions/workflows/pr-quiz.yml");
def para($text): if ($text // "") == "" then "" else "<p>\($text | e)</p>" end;

"<!doctype html>
<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
<title>PR #\(.pr): \(.title | e)</title>
<style>
:root{--bg:#0d1117;--fg:#e6edf3;--muted:#8b949e;--card:#161b22;--border:#30363d;--accent:#58a6ff;--ok:#3fb950;--warn:#d29922;--chip:#1f6feb33}
@media (prefers-color-scheme: light){:root{--bg:#f6f8fa;--fg:#1f2328;--muted:#59636e;--card:#fff;--border:#d1d9e0;--accent:#0969da;--ok:#1a7f37;--warn:#9a6700;--chip:#ddf4ff}}
*{box-sizing:border-box}body{margin:0;font:16px/1.6 -apple-system,BlinkMacSystemFont,\"Segoe UI\",Helvetica,Arial,sans-serif;background:var(--bg);color:var(--fg)}
main{max-width:920px;margin:0 auto;padding:32px 20px 64px}
a{color:var(--accent)}header{margin-bottom:24px}header .meta{color:var(--muted);font-size:14px}
h1{font-size:28px;margin:4px 0 12px}.tldr{font-size:18px;border-left:4px solid var(--accent);padding:8px 16px;background:var(--card);border-radius:0 8px 8px 0}
.card{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:16px 20px;margin:16px 0}
.card h2{font-size:18px;margin:0 0 8px;display:flex;gap:8px;align-items:center}.icon{font-size:20px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:12px}
.change{border:1px solid var(--border);border-radius:10px;padding:12px 14px}.change b{display:block;margin-bottom:4px}
table{width:100%;border-collapse:collapse}td,th{border-top:1px solid var(--border);padding:8px;text-align:left;vertical-align:top}th{color:var(--muted);font-weight:600}
.chip{display:inline-block;background:var(--chip);color:var(--accent);border-radius:999px;padding:0 10px;font-size:12px;font-weight:600;margin-right:6px}
.q{border:1px solid var(--border);border-radius:10px;padding:12px 16px;margin:12px 0}.q h3{font-size:16px;margin:0 0 8px}
.q label{display:block;padding:6px 10px;border-radius:8px;cursor:pointer}.q label:hover{background:var(--chip)}
.q input{margin-right:8px}
.answer{margin-top:16px}.answer a{display:inline-block;background:var(--ok);color:#fff;border-radius:8px;padding:8px 14px;font-weight:600;text-decoration:none}
.note{color:var(--muted);font-size:14px}
</style></head><body><main>
<header><div class=\"meta\">Pull request <a href=\"\(.pr_url | e)\">#\(.pr)</a> · commit <code>\(.head_sha[0:8])</code></div>
<h1>\(.title | e)</h1><div class=\"tldr\">\(.tldr | e)</div></header>"
+ card("🎯"; "Why"; para(.why))
+ card("🧭"; "Intent"; para(.intent))
+ card("🧩"; "What changed"; if (.what // []) == [] then "" else
    "<div class=\"grid\">" + ((.what) | map("<div class=\"change\"><b>\(.title | e)</b>\(.detail | e)</div>") | join("")) + "</div>" end)
+ card("⚖️"; "Key decisions"; if (.decisions // []) == [] then "" else
    "<table><tr><th>Decision</th><th>Reason</th></tr>" + ((.decisions) | map("<tr><td>\(.decision | e)</td><td>\(.reason | e)</td></tr>") | join("")) + "</table>" end)
+ card("⚠️"; "Risks and follow-ups"; list(.risks))
+ card("🚫"; "Out of scope"; list(.out_of_scope))
+ card("💬"; "Review discussion"; if (.review_discussion // []) == [] then "" else
    "<ul>" + ((.review_discussion) | map("<li><span class=\"chip\">\(.source | e)</span>\(.topic | e) → \(.outcome | e)</li>") | join("")) + "</ul>" end)
+ "<section class=\"card\"><h2><span class=\"icon\">📝</span>Comprehension quiz</h2>"
+ "<p class=\"note\">\(.questions | length) questions. Pass mark \(.pass_mark)%, \(.max_attempts) attempts per reviewer. " + (if .allow_author then "Only reviewers requested on the pull request and its author can answer. " else "Only reviewers requested on the pull request can answer. " end)
+ "Tick your answers here, then open the answer form, click <b>Run workflow</b>, enter PR <b>\(.pr)</b> and quiz ID <code>\(.quiz_id | e)</code>, and choose the same letters for Q1 to Q\(.questions | length).</p>"
+ ([.questions | to_entries[] | . as $q |
    "<div class=\"q\"><h3>Q\($q.key + 1). \($q.value.question | e)</h3>"
    + ($q.value.options | to_entries | map(
        "<label><input type=\"radio\" name=\"q\($q.key)\" value=\"\(letter(.key))\"><b>\(letter(.key)))</b> \(.value | e)</label>") | join(""))
    + "</div>"] | join(""))
+ "<div class=\"answer\"><a href=\"\(answer_url | e)\" target=\"_blank\" rel=\"noopener\">Open the answer form ↗</a></div></section>
</main></body></html>"
