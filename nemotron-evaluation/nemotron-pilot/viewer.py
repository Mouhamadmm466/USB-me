#!/usr/bin/env python3
"""Build offline, inspectable test catalogs and run reports. Python 3.9+."""
import argparse
import collections
import html
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent
TIERS = ("easy", "medium", "hard")
CSS = """
:root { color-scheme: light; --ink:#172638; --muted:#536478; --line:#d8e1ea;
  --paper:#fff; --wash:#f3f6fa; --accent:#125e70; }
* { box-sizing:border-box; }
body { margin:0; background:var(--wash); color:var(--ink);
  font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
main { max-width:1100px; margin:0 auto; padding:42px 24px 64px; }
header { margin-bottom:28px; }
.eyebrow { color:var(--accent); font-size:.78rem; font-weight:750;
  text-transform:uppercase; letter-spacing:.12em; margin:0; }
h1 { font-size:clamp(1.8rem,4vw,2.7rem); line-height:1.15; margin:.4em 0; }
h2 { font-size:1.35rem; margin:1.6em 0 .8em; }
h3 { font-size:1.05rem; margin:1.2em 0 .5em; }
p { margin:.6em 0 1em; }
a { color:var(--accent); text-underline-offset:3px; }
nav { display:flex; flex-wrap:wrap; gap:18px; margin-top:16px; }
.muted, .meta { color:var(--muted); }
.meta { font-size:.9rem; }
.notice { border-left:4px solid var(--accent); padding:14px 18px;
  background:#e8f3f5; border-radius:0 8px 8px 0; margin:20px 0; }
.warning { background:#fff3df; border-color:#9c600c; }
.stats { display:grid; grid-template-columns:repeat(auto-fit,minmax(160px,1fr));
  gap:12px; margin:24px 0; }
.stat { background:var(--paper); border:1px solid var(--line); border-radius:10px;
  padding:16px 20px; }
.stat strong { display:block; font-size:2rem; line-height:1.3; }
.stat span { color:var(--muted); font-size:.9rem; }
.table-wrap { overflow-x:auto; background:var(--paper); border:1px solid var(--line);
  border-radius:10px; }
table { width:100%; border-collapse:collapse; text-align:left; font-size:.93rem; }
caption { padding:14px 18px; text-align:left; font-weight:650; }
th,td { padding:12px 16px; border-top:1px solid var(--line); vertical-align:top; }
thead th { background:#edf2f7; }
.case { margin:16px 0; padding:20px 24px; border:1px solid var(--line);
  border-radius:12px; background:var(--paper); }
.case > summary { font-weight:700; font-size:1.1rem; }
.case > summary .badge { margin-right:8px; }
.case-body { padding-top:10px; }
summary { cursor:pointer; padding:6px 0; }
summary:focus-visible, a:focus-visible { outline:3px solid #3972c6; outline-offset:4px; }
details details { border-top:1px solid var(--line); margin-top:14px; padding-top:7px; }
pre { white-space:pre-wrap; overflow-wrap:anywhere; background:#f4f7fa; padding:16px;
  border-radius:8px; font: .86rem/1.6 ui-monospace,SFMono-Regular,Consolas,monospace; }
blockquote { white-space:pre-wrap; overflow-wrap:anywhere; margin:12px 0 18px;
  padding:12px 18px; border-left:3px solid #adc8d2; background:#f5fafb; }
.badge { display:inline-block; font-size:.75rem; letter-spacing:.025em;
  font-weight:650; padding:3px 9px; border-radius:5px; background:#e8eef6; color:#30465f; }
.pass { background:#e1f3e9; color:#1d5d3d; }
.fail { background:#fce8e6; color:#94392e; }
.pending { background:#fff0d2; color:#7c5010; }
.statuses { display:flex; flex-wrap:wrap; gap:8px; margin:12px 0; }
li { margin:7px 0; overflow-wrap:anywhere; }
footer { margin-top:32px; font-size:.9rem; color:var(--muted); }
@media (max-width:600px) { main { padding:28px 16px; } .case { padding:16px; } }
@media print { body { background:white; } main { max-width:none; padding:0; }
  nav { display:none; } .case { break-inside:avoid; } }
"""


def escape(value):
    return html.escape(str(value), quote=True)


def as_json(value):
    return json.dumps(value, ensure_ascii=False, indent=2)


def pre(value, raw=False):
    return "<pre>" + escape(value if raw else as_json(value)) + "</pre>"


def details(title, content, opened=False):
    return '<details%s><summary>%s</summary>%s</details>' % (
        " open" if opened else "", escape(title), content)


def checklist(values):
    if not values:
        return '<p class="muted">None recorded.</p>'
    return "<ul>" + "".join("<li>" + escape(v) + "</li>" for v in values) + "</ul>"


def badge(label, kind=""):
    return '<span class="badge %s">%s</span>' % (escape(kind), escape(label))


def page(title, subtitle, content):
    return """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
<title>%s</title><style>%s</style></head><body><main>
<header><p class="eyebrow">USB-Me · model decision pilot</p><h1>%s</h1><p class="muted">%s</p></header>
%s
<footer>Exposed development cases cannot establish general accuracy or safety. These are independent next-decision checks, not full conversations, app integration tests, or iPhone/audio benchmarks. No real actions execute.</footer>
</main></body></html>
""" % (escape(title), CSS, escape(title), escape(subtitle), content)


def atomic_text(path, content):
    path = pathlib.Path(path)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(content, encoding="utf-8")
    temporary.replace(path)
    return path


def fenced(value, raw=False):
    text = str(value) if raw else as_json(value)
    fence = "`" * max(3, 1 + max((len(v) for v in re.findall(r"`+", text)), default=0))
    return fence + ("text" if raw else "json") + "\n" + text + "\n" + fence


def generate_cases(root=ROOT):
    """Write TESTS.md and tests.html; return their paths in that order."""
    root = pathlib.Path(root)
    dataset = json.loads((root / "cases.json").read_text(encoding="utf-8"))
    prompt = (root / "system_prompt.txt").read_text(encoding="utf-8")
    counts = collections.Counter(c["difficulty"] for c in dataset["cases"])
    count_text = " · ".join("%s %s" % (counts[t], t) for t in TIERS)
    body = ['<p class="notice">Inspect the request, supplied state, expected structured fields, and speech criteria for each case. Automatic field checks are provisional until a human reviews the speech and answer key.</p>',
            '<nav aria-label="Difficulty levels">' + "".join('<a href="#%s">%s (%s)</a>' % (t, t.title(), counts[t]) for t in TIERS) + '</nav>',
            details("Shared environment", pre(dataset.get("environment", {}))),
            details("System prompt sent to the model", pre(prompt, raw=True)),
            '<p class="meta">Dataset: %s · %s</p>' % (escape(dataset.get("version", "Unknown")), escape(dataset.get("review_status", "")))]
    markdown = ["# USB-Me: %d test cases" % len(dataset["cases"]), "", count_text, "",
                escape(dataset.get("scope", "")), "", escape(dataset.get("review_status", "")), "",
                "Automatic checks compare the structured response; a human must review speech and the answer key.", "",
                "## Shared environment", "", fenced(dataset.get("environment", {})), "",
                "## System prompt", "", fenced(prompt, raw=True)]
    for tier in TIERS:
        body.append('<section id="%s"><h2>%s · %s cases</h2>' % (tier, tier.title(), counts[tier]))
        markdown.extend(["", "## " + tier.title()])
        for case in (c for c in dataset["cases"] if c["difficulty"] == tier):
            title = str(case["id"]) + " · " + str(case["title"])
            inp = case.get("input", {})
            body.append('<details class="case"><summary>%s</summary><div class="case-body">' % escape(title))
            body.append('<p class="meta">%s</p><h3>User request</h3><blockquote>%s</blockquote>' % (
                escape(case.get("rationale", "")), escape(inp.get("user_request", ""))))
            body.append(details("Supplied state", pre(inp.get("state", {}))))
            body.append(details("Case environment", pre(dict(dataset.get("environment", {}), **case.get("environment", {})))))
            body.append('<p class="meta">Category: %s · Tags: %s</p>' % (escape(case.get("category", "Legacy")), escape(", ".join(case.get("tags", [])))))
            body.append(details("Expected structured fields", pre(case.get("expected", {}))))
            body.append(details("Human review criteria", checklist(case.get("human_checks", []))))
            body.append(details("Requirements", checklist(case.get("requirements", []))))
            body.append('</div></details>')
            markdown.extend(["", "### " + escape(title), "", escape(case.get("rationale", "")), "",
                             "User request:", "", fenced(inp.get("user_request", ""), raw=True), "",
                             "Supplied state:", "", fenced(inp.get("state", {})), "",
                             "Case environment:", "", fenced(dict(dataset.get("environment", {}), **case.get("environment", {}))), "",
                             "Expected structured fields:", "", fenced(case.get("expected", {})), "",
                             "Human review criteria:", ""])
            markdown.extend("- " + escape(check) for check in case.get("human_checks", []))
            markdown.extend(["", "Requirements: " + "; ".join(escape(r) for r in case.get("requirements", []))])
        body.append('</section>')
    md_path = atomic_text(root / "TESTS.md", "\n".join(markdown) + "\n")
    html_path = atomic_text(root / "tests.html", page("The %d tests" % len(dataset["cases"]), count_text, "\n".join(body)))
    return md_path, html_path


def reviewed(item):
    return isinstance(item.get("human_review"), dict)


def review_pass(item):
    return item.get("auto_pass") is True and reviewed(item) and item["human_review"].get("passed") is True


def stat(value, label):
    return '<div class="stat"><strong>%s</strong><span>%s</span></div>' % (escape(value), escape(label))


def render_report(directory, report):
    """Write directory/report.html from a saved-report dictionary; return its Path.

    Uses the run's dataset.json snapshot when available to show unattempted cases.
    Never modifies results, review decisions, or pointers to latest runs.
    """
    directory = pathlib.Path(directory)
    results = report.get("results", [])
    snapshot_path = directory / "dataset.json"
    snapshot = json.loads(snapshot_path.read_text(encoding="utf-8")) if snapshot_path.exists() else {}
    cases = snapshot.get("cases", [])
    planned = report.get("planned_cases", len(cases) or 9)
    remaining = max(0, planned - len(results))
    pending = sum(not reviewed(item) for item in results)
    incomplete = report.get("status") == "incomplete" or len(results) != planned
    body = ['<p class="meta">Run: %s<br>Started: %s<br>Status: %s</p>' % (
        escape(directory.name), escape(report.get("started_at", "Not recorded")), escape(report.get("status", "Unknown"))),
        '<div class="stats">' + stat(planned, "Planned cases") + stat(len(results), "Attempted cases") +
        stat(sum(item.get("auto_pass") is True for item in results), "Automatic passes · provisional") +
        stat(pending, "Attempted cases awaiting human review") + '</div>',
        '<p class="notice">Automatic passes check structured fields only and remain provisional until speech and the answer key are reviewed. Assistant review, if present, is separate from human review and does not count as a human decision.</p>']
    if incomplete:
        body.append('<p class="notice warning"><strong>Incomplete run.</strong> %s of %s planned cases attempted; %s not attempted. Partial results are not a completed model score.</p>' % (len(results), escape(planned), remaining))
    if report.get("error"):
        body.append('<div class="notice warning"><strong>Run error</strong>' + pre(report["error"], raw=True) + '</div>')
    body.append('<div class="table-wrap"><table><caption>Results by difficulty</caption><thead><tr><th scope="col">Difficulty</th><th scope="col">Attempted / planned</th><th scope="col">Automatic passes<br>(provisional)</th><th scope="col">Human reviewed</th><th scope="col">Human pending</th><th scope="col">Reviewed passes</th></tr></thead><tbody>')
    tier_planned = report.get("planned_by_tier") or collections.Counter(c.get("difficulty") for c in cases)
    for tier in TIERS:
        items = [r for r in results if r.get("difficulty") == tier]
        count = tier_planned.get(tier, planned // 3)
        body.append('<tr><th scope="row">%s</th><td>%s / %s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>' % (
            tier.title(), len(items), count, sum(i.get("auto_pass") is True for i in items),
            sum(reviewed(i) for i in items), sum(not reviewed(i) for i in items), sum(review_pass(i) for i in items)))
    body.append('</tbody></table></div><h2>Case details</h2>')
    if not results:
        body.append('<p class="muted">No model requests have been recorded.</p>')
    for item in results:
        title = str(item.get("id", "?")) + " · " + str(item.get("title", "Untitled case"))
        body.append('<details class="case" open><summary>%s %s</summary><div class="case-body">' % (
            badge(item.get("difficulty", "Unknown difficulty")), escape(title)))
        auto_ok = item.get("auto_pass") is True
        human = item.get("human_review")
        human_label = "Human review pending" if not reviewed(item) else (
            "Human review passed" if human.get("passed") is True else "Human review failed")
        human_kind = "pending" if not reviewed(item) else ("pass" if human.get("passed") is True else "fail")
        body.append('<div class="statuses">' + badge("Automatic pass · provisional" if auto_ok else "Automatic checks failed", "pass" if auto_ok else "fail") + badge(human_label, human_kind) + '</div>')
        if item.get("harness_error"):
            body.append('<p class="notice warning">Harness or server configuration error; this is not a model failure score.</p>')
        elapsed = item.get("elapsed_seconds")
        if isinstance(elapsed, (int, float)):
            body.append('<p class="meta">Request elapsed: %.3f seconds</p>' % elapsed)
        inp = item.get("input", {})
        body.append('<h3>User request</h3><blockquote>%s</blockquote>' % escape(inp.get("user_request", "Not recorded")))
        actual = item.get("actual")
        speech = actual.get("speech") if isinstance(actual, dict) else None
        body.append('<h3>Model speech</h3><blockquote>%s</blockquote>' % escape(speech if speech is not None else "No parsed speech available."))
        body.append(details("Actual structured response", pre(actual)))
        body.append(details("Expected structured fields", pre(item.get("expected"))))
        body.append(details("Supplied state", pre(inp.get("state", {}))))
        body.append(details("Case environment", pre(item.get("environment", snapshot.get("environment", {})))))
        body.append(details("Human review criteria", checklist(item.get("human_checks", []))))
        body.append(details("Automatic errors (%s)" % len(item.get("errors", [])), checklist(item.get("errors", [])), opened=bool(item.get("errors"))))
        body.append(details("Human review record", pre(human) if reviewed(item) else '<p class="muted">Pending. Use python3 pilot.py review to record your assessment.</p>'))
        if "assistant_review" in item:
            body.append(details("Assistant review (does not replace human review)", pre(item["assistant_review"]), opened=True))
        body.append(details("Raw model content", pre(item.get("raw_content"), raw=isinstance(item.get("raw_content"), str))))
        body.append(details("Raw server response", pre(item.get("raw_response"))))
        body.append(details("Exact model request", pre(item.get("request"))))
        body.append('</div></details>')
    attempted_ids = {r.get("id") for r in results}
    for case in (c for c in cases if c.get("id") not in attempted_ids):
        body.append('<details class="case"><summary>%s %s</summary><div class="case-body">%s<blockquote>%s</blockquote>%s%s</div></details>' % (
            badge(case.get("difficulty", "Unknown")), escape(str(case.get("id")) + " · " + str(case.get("title"))),
            badge("Not attempted", "pending"), escape(case.get("input", {}).get("user_request", "")),
            details("Expected structured fields", pre(case.get("expected"))),
            details("Human review criteria", checklist(case.get("human_checks", [])))))
    metadata = {key: value for key, value in report.items() if key != "results"}
    body.append(details("Run metadata and provenance", pre(metadata)))
    body.append('<p class="meta">Request times include HTTP and full generation, may include warm-up, and are not iPhone latency or time-to-first-token. This page is a static snapshot; regenerate it after changing a review record.</p>')
    return atomic_text(directory / "report.html", page("Test run report", "Every request, response, check, and review in one place.", "\n".join(body)))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("cases", "report"))
    parser.add_argument("--run", help="Run directory name; defaults to runs/LATEST")
    args = parser.parse_args(argv)
    try:
        if args.action == "cases":
            for path in generate_cases():
                print(path)
        else:
            name = args.run or (ROOT / "runs" / "LATEST").read_text(encoding="utf-8").strip()
            if not name or pathlib.Path(name).name != name or name in (".", ".."):
                raise ValueError("--run must be a run directory name")
            directory = ROOT / "runs" / name
            report = json.loads((directory / "results.json").read_text(encoding="utf-8"))
            print(render_report(directory, report))
        return 0
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print("Viewer error: " + str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
