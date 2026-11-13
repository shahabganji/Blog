#!/usr/bin/env python3
"""Render a `pulumi preview` run as a GitHub-flavoured Markdown report (PR comment / job summary).

Usage: preview_report.py <event-log.jsonl> <preview-output.txt> <step-outcome>
Reads optional env: STACK, GITHUB_SERVER_URL, GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_SHA, PR_HEAD_SHA.
"""
import json
import os
import re
import sys
from datetime import datetime, timezone

MARKER = "<!-- pulumi-preview-report -->"
MAX_DIFF_CHARS = 45_000

# op -> (emoji, label, badge colour)
OPS = {
    "create": ("🟢", "create", "2ea44f"),
    "update": ("🟡", "update", "dbab09"),
    "replace": ("🟠", "replace", "fb8f44"),
    "delete": ("🔴", "delete", "d73a49"),
    "import": ("🔵", "import", "0969da"),
    "same": ("⚪", "unchanged", "8b949e"),
}
# Engine steps that are part of a replacement are folded into the "replace" step.
OP_ALIASES = {"create-replacement": "replace", "delete-replaced": "replace", "discard": "delete", "import-replacement": "import"}

COLOR_TAGS = re.compile(r"<\{%[^%]*%\}>")
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def clean(text):
    return ANSI.sub("", COLOR_TAGS.sub("", text or "")).strip()


def read_events(path):
    events = []
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if line:
                    try:
                        events.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass
    except FileNotFoundError:
        pass
    return events


def analyse(events):
    steps = {}
    summary = None
    errors = []
    for event in events:
        if "resourcePreEvent" in event:
            meta = event["resourcePreEvent"].get("metadata", {})
            op = OP_ALIASES.get(meta.get("op"), meta.get("op"))
            urn = meta.get("urn", "")
            if op not in OPS or op == "same" or meta.get("type") == "pulumi:pulumi:Stack":
                continue
            state = meta.get("new") or meta.get("old") or {}
            props = sorted((meta.get("detailedDiff") or {}).keys()) or sorted(meta.get("diffs") or [])
            existing = steps.get(urn)
            if existing is None or op == "replace":
                steps[urn] = {
                    "op": op,
                    "type": meta.get("type", ""),
                    "name": urn.split("::")[-1],
                    "props": props or (existing or {}).get("props", []),
                    "protected": bool(state.get("protect")),
                }
        elif "summaryEvent" in event:
            summary = event["summaryEvent"].get("resourceChanges") or {}
        elif "diagnosticEvent" in event:
            diag = event["diagnosticEvent"]
            if diag.get("severity") == "error":
                message = clean(diag.get("message"))
                if message and message not in errors:
                    errors.append(message)
    if summary is None:
        summary = {}
        for step in steps.values():
            summary[step["op"]] = summary.get(step["op"], 0) + 1
    counts = {}
    for op, count in summary.items():
        op = OP_ALIASES.get(op, op)
        if op in OPS and count:
            counts[op] = counts.get(op, 0) + count
    return list(steps.values()), counts, errors


def to_diff_block(output):
    """Move Pulumi's +/-/~ markers to column 0 so GitHub's `diff` highlighter colours them."""
    lines = []
    in_build = False
    for raw in clean(output).splitlines():
        # Drop the `dotnet build` chatter and the "View Live" link (it is in the footer).
        if raw.startswith("running '"):
            in_build = True
        if in_build:
            in_build = not raw.endswith("completed successfully")
            continue
        if raw.startswith("View Live:") or raw.lstrip().startswith("[provider="):
            continue
        match = re.match(r"^(\s*)(\+-|-\+|[+\-~])(\s.*)$", raw)
        if match:
            marker = match.group(2)
            symbol = "!" if marker in ("~", "+-", "-+") else marker
            lines.append(f"{symbol}{match.group(1)}{match.group(3)}")
        else:
            lines.append(f" {raw}")
    text = "\n".join(lines)
    if len(text) > MAX_DIFF_CHARS:
        text = text[:MAX_DIFF_CHARS] + "\n … (truncated, see the workflow run for the full output)"
    return text


def badge(op, count):
    _, label, colour = OPS[op]
    return f"![{label}: {count}](https://img.shields.io/badge/{label}-{count}-{colour}?style=flat-square)"


def render(event_log, output_file, outcome):
    steps, counts, errors = analyse(read_events(event_log))
    try:
        with open(output_file, encoding="utf-8") as handle:
            output = handle.read()
    except FileNotFoundError:
        output = ""

    stack = os.environ.get("STACK", "")
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    run_url = f"{server}/{repo}/actions/runs/{os.environ.get('GITHUB_RUN_ID', '')}"
    sha = os.environ.get("PR_HEAD_SHA") or os.environ.get("GITHUB_SHA", "")
    cloud = re.search(r"https://app\.pulumi\.com/\S+", clean(output))

    destructive = [s for s in steps if s["op"] in ("replace", "delete")]
    changed = sum(c for op, c in counts.items() if op != "same")
    unchanged = counts.get("same", 0)

    md = [MARKER, f"## 🍹 Pulumi preview · `{stack}`", ""]
    if outcome != "success":
        md += ["> [!CAUTION]", "> ❌ **Preview failed.** Nothing was changed. Fix the errors below before merging.", ""]
    elif destructive:
        md += [
            "> [!CAUTION]",
            f"> 🛑 **{len(destructive)} resource(s) would be replaced or deleted.** "
            "Every resource is `protect`ed, so `pulumi up` will refuse until protection is removed deliberately.",
            "",
        ]
    elif changed:
        md += [
            "> [!WARNING]",
            f"> ✏️ **{changed} change(s) to production.** "
            "They are applied only after a `release/v*` tag is pushed and the `prod` deployment is approved.",
            "",
        ]
    else:
        md += ["> [!TIP]", f"> ✅ **No changes.** Azure matches the code ({unchanged} resources unchanged).", ""]

    if counts:
        order = ["create", "update", "replace", "delete", "import", "same"]
        md += [" ".join(badge(op, counts[op]) for op in order if op in counts), ""]

    if errors:
        md += ["### ❌ Errors", ""]
        for message in errors:
            md += ["```", message, "```"]
        md.append("")

    if steps:
        rank = {"delete": 0, "replace": 1, "create": 2, "update": 3, "import": 4}
        md += ["### Changes", "", "| | Operation | Resource | Type | Changed properties |", "|:-:|---|---|---|---|"]
        for step in sorted(steps, key=lambda s: (rank.get(s["op"], 9), s["type"], s["name"])):
            emoji, label, _ = OPS[step["op"]]
            props = ", ".join(f"`{p}`" for p in step["props"][:8]) or "—"
            if len(step["props"]) > 8:
                props += f" +{len(step['props']) - 8} more"
            lock = " 🔒" if step["protected"] else ""
            md.append(f"| {emoji} | **{label}** | `{step['name']}`{lock} | `{step['type']}` | {props} |")
        md.append("")

    if output.strip():
        is_open = " open" if steps or outcome != "success" else ""
        md += [f"<details{is_open}><summary>📄 Full preview output</summary>", "", "```diff", to_diff_block(output), "```", "", "</details>", ""]

    links = []
    if cloud:
        links.append(f"[☁️ Pulumi Cloud]({cloud.group(0)})")
    links.append(f"[⚙️ Workflow run]({run_url})")
    if sha:
        links.append(f"commit [`{sha[:7]}`]({server}/{repo}/commit/{sha})")
    links.append(f"updated {datetime.now(timezone.utc):%Y-%m-%d %H:%M} UTC")
    md.append("<sub>" + " · ".join(links) + "</sub>")
    return "\n".join(md) + "\n"


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    sys.stdout.write(render(*sys.argv[1:]))
