#!/usr/bin/env python3
"""150-case model-only voice-assistant evaluation. Python 3.9+; standard library only."""
import argparse
import collections
import datetime as dt
import getpass
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from viewer import render_report

ROOT = pathlib.Path(__file__).resolve().parent
MODEL_FILE = "NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf"
MODEL_SHA = "be5d9a656a51922f24f1f09a759cebb694e1f5d9728bf0ef9f8c972c5a0b5ef2"
MODEL_REV = "1260a7780236524372acab3fdff3da563b611a2c"
ALIAS = "usb-me-nemotron-4b-q4km"
BASE_URL = "http://127.0.0.1:8080"
CONTAINER = "usb-me-pilot-server"
WORKFLOW_VERSION = "3.0"
TIER_COUNTS = {"easy": 50, "medium": 50, "hard": 50}
IMAGE_DIGEST = "ghcr.io/ggml-org/llama.cpp@sha256:131a7be5d90d6df75f32ffad405d71e354e9bdba806264b6a905339283925b85"
TOOLS = ["search_contacts", "initiate_call", "compose_message", "get_calendar_events",
         "create_calendar_event", "update_calendar_event", "create_reminder",
         "search_files", "open_file", "open_supported_app"]
ARGUMENT_KEYS = ["contact_query", "message", "title", "due_at", "event_id", "starts_at",
                 "ends_at", "query", "contact_id", "phone_number", "file_id", "app_id",
                 "scope_id", "calendar_id", "location"]
WRITE_TOOLS = {"compose_message", "initiate_call", "create_reminder", "create_calendar_event", "update_calendar_event"}
CONTRACTS = {
    "search_contacts": ({"query"}, {"query"}),
    "initiate_call": ({"phone_number"}, {"contact_id", "phone_number"}),
    "compose_message": ({"contact_query", "message"}, {"contact_query", "message"}),
    "get_calendar_events": ({"starts_at", "ends_at"}, {"starts_at", "ends_at"}),
    "create_calendar_event": ({"title", "starts_at", "ends_at", "calendar_id"}, {"title", "starts_at", "ends_at", "calendar_id", "location"}),
    "update_calendar_event": ({"event_id"}, {"event_id", "title", "starts_at", "ends_at", "location"}),
    "create_reminder": ({"title", "due_at"}, {"title", "due_at"}),
    "search_files": ({"query", "scope_id"}, {"query", "scope_id"}),
    "open_file": ({"file_id"}, {"file_id"}),
    "open_supported_app": ({"app_id"}, {"app_id"}),
}
SCHEMA = {
    "type": "object", "additionalProperties": False,
    "required": ["type", "speech", "tool", "arguments", "requires_confirmation"],
    "properties": {
        "type": {"type": "string", "enum": ["answer", "clarification", "proposed_action", "unsupported"]},
        "speech": {"type": "string", "minLength": 1, "maxLength": 600},
        "tool": {"type": ["string", "null"], "enum": TOOLS + [None]},
        "arguments": {"type": "object", "properties": {k: {"type": "string"} for k in ARGUMENT_KEYS},
                      "additionalProperties": False},
        "requires_confirmation": {"type": "boolean"},
    },
}


def strict_json(text):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("Duplicate JSON key: " + key)
            result[key] = value
        return result

    def constant(value):
        raise ValueError("Nonstandard JSON constant: " + value)

    return json.loads(text, object_pairs_hook=pairs, parse_constant=constant)


def sha_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def utc_now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def save_json(path, obj):
    path = pathlib.Path(path)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    tmp.replace(path)


def timestamp(value):
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("Timestamp must include a timezone")
    return parsed.astimezone(dt.timezone.utc)


def grade(raw, expected):
    """No semantic speech score is inferred here; a human must review it."""
    try:
        actual = strict_json(raw)
    except (ValueError, TypeError) as exc:
        return None, ["Invalid JSON: " + str(exc)]
    if not isinstance(actual, dict):
        return actual, ["Response must be one JSON object"]
    errors = []
    if set(actual) != set(SCHEMA["required"]):
        errors.append("Missing or extra top-level fields")
    speech = actual.get("speech")
    if not isinstance(speech, str) or not speech.strip() or len(speech) > 600:
        errors.append("speech must be nonempty text, at most 600 characters")
    if type(actual.get("requires_confirmation")) is not bool:
        errors.append("requires_confirmation must be a JSON boolean")
    if actual.get("type") not in SCHEMA["properties"]["type"]["enum"]:
        errors.append("Unknown response type")
    if actual.get("tool") not in TOOLS + [None]:
        errors.append("Unknown tool")
    for key in ("type", "tool", "requires_confirmation"):
        if actual.get(key) != expected[key]:
            errors.append("%s: expected %r; got %r" % (key, expected[key], actual.get(key)))
    arguments = actual.get("arguments")
    if not isinstance(arguments, dict):
        errors.append("arguments must be an object")
    else:
        if set(arguments) != set(expected["arguments"]):
            errors.append("Argument names do not match the required decision")
        for key, value in arguments.items():
            if key not in ARGUMENT_KEYS or not isinstance(value, str):
                errors.append("Invalid argument field/type: " + key)
        for key, value in expected["arguments"].items():
            found = arguments.get(key)
            if key in ("due_at", "starts_at", "ends_at"):
                try:
                    matches = timestamp(found) == timestamp(value)
                except (ValueError, TypeError, AttributeError):
                    matches = False
            else:
                matches = found == value
            if not matches:
                errors.append("arguments.%s: expected %r; got %r" % (key, value, found))
    return actual, errors


def load_cases():
    dataset = strict_json((ROOT / "cases.json").read_text(encoding="utf-8"))
    cases = dataset["cases"]
    if len(cases) != sum(TIER_COUNTS.values()) or collections.Counter(c["difficulty"] for c in cases) != TIER_COUNTS:
        raise ValueError("Dataset must contain exactly 50 easy, 50 medium, and 50 hard cases")
    if len({c["id"] for c in cases}) != len(cases):
        raise ValueError("Duplicate case IDs")
    for field in ("title", "coverage_key"):
        values = [c[field].strip().casefold() for c in cases]
        if len(set(values)) != len(cases):
            raise ValueError("Duplicate case " + field)
    requests = [c["input"]["user_request"].strip().casefold() for c in cases]
    if len(set(requests)) != len(cases):
        raise ValueError("Duplicate user requests; each case must be distinct")
    for case in cases:
        for key in ("title", "rationale", "requirements", "human_checks", "category", "coverage_key", "tags"):
            if not case.get(key):
                raise ValueError("Missing case metadata: " + key)
        if set(case["input"]) != {"state", "user_request"}:
            raise ValueError("Unexpected model-input fields")
        _, errors = grade(json.dumps(dict(case["expected"], speech="Schema validation placeholder.")), case["expected"])
        if errors:
            raise ValueError("Invalid expected contract for " + case["id"] + ": " + str(errors))
        expected = case["expected"]
        tool = expected["tool"]
        if expected["type"] == "proposed_action":
            if tool not in CONTRACTS:
                raise ValueError("Proposal has no supported tool: " + case["id"])
            required, allowed = CONTRACTS[tool]
            keys = set(expected["arguments"])
            if not required <= keys <= allowed or (tool == "update_calendar_event" and keys == {"event_id"}):
                raise ValueError("Invalid tool argument contract: " + case["id"])
            if expected["requires_confirmation"] != (tool in WRITE_TOOLS):
                raise ValueError("Incorrect confirmation contract: " + case["id"])
        elif tool is not None or expected["arguments"] or expected["requires_confirmation"]:
            raise ValueError("Non-proposal must not contain an action: " + case["id"])
        for key in ("due_at", "starts_at", "ends_at"):
            if key in expected["arguments"]:
                timestamp(expected["arguments"][key])
        if {"starts_at", "ends_at"} <= set(expected["arguments"]):
            if timestamp(expected["arguments"]["ends_at"]) <= timestamp(expected["arguments"]["starts_at"]):
                raise ValueError("Event or query must end after it starts: " + case["id"])
    exercised = {c["expected"]["tool"] for c in cases}
    if not set(TOOLS) <= exercised:
        raise ValueError("Dataset must exercise all ten supported tools")
    return dataset


def make_request(dataset, case, system_prompt):
    # Explicit selection prevents expected answers, difficulty labels, review checks,
    # IDs, and future information from leaking into model-visible messages.
    envelope = {"environment": dict(dataset["environment"], **case.get("environment", {})), "state": case["input"]["state"],
                "user_request": case["input"]["user_request"]}
    return {
        "model": ALIAS,
        "messages": [{"role": "system", "content": system_prompt},
                     {"role": "user", "content": json.dumps(envelope, ensure_ascii=False)}],
        "temperature": 0, "seed": 42, "max_tokens": 512, "stream": False,
        "cache_prompt": False, "reasoning_effort": "none",
        "chat_template_kwargs": {"enable_thinking": False},
        "response_format": {"type": "json_object", "schema": SCHEMA},
    }


def http_json(route, payload=None, timeout=120):
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(BASE_URL + route, data=data, headers={"Content-Type": "application/json"})
    # The runner is intentionally restricted to this local server; no public API key.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req, timeout=timeout) as response:
        return strict_json(response.read().decode("utf-8"))


def command(args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, timeout=30).strip()


def verify_container(inspected):
    config = inspected["Config"]
    expected_command = ["--model", "/models/" + MODEL_FILE, "--alias", ALIAS,
                        "--n-gpu-layers", "999", "--ctx-size", "4096", "--parallel", "1",
                        "--jinja", "--reasoning", "off", "--host", "127.0.0.1", "--port", "8080"]
    if (config.get("Labels") or {}).get("usb-me.purpose") != "nine-case-pilot":
        raise ValueError("Existing container is not labeled as this package's pilot server")
    if config.get("Image") != IMAGE_DIGEST:
        raise ValueError("Server image differs from the workflow's verified runtime digest")
    if config.get("Cmd") != expected_command:
        raise ValueError("Existing server launch arguments differ from this pilot's settings")
    host_config = inspected.get("HostConfig", {})
    if host_config.get("NetworkMode") != "host" or host_config.get("PortBindings"):
        raise ValueError("Server must use the VM host network and bind only to 127.0.0.1")
    if not host_config.get("DeviceRequests"):
        raise ValueError("Server was not launched with GPU access")


def preflight(runtime=None):
    if runtime is None:
        runtime = strict_json((ROOT / "runtime.json").read_text(encoding="utf-8"))
    runtime = dict(runtime)
    model_path = pathlib.Path(runtime["model_file"])
    if sha_file(model_path) != MODEL_SHA:
        raise ValueError("Model file checksum does not match the PRD-pinned artifact")
    inspected = strict_json(command(["docker", "inspect", CONTAINER]))[0]
    verify_container(inspected)
    if inspected["Id"] != runtime["container_id"] or not inspected["State"]["Running"]:
        raise ValueError("Server container changed/stopped; rerun start_model.sh")
    if inspected["Config"]["Image"] != runtime["image_digest"]:
        raise ValueError("Container image differs from recorded digest")
    mount_ok = any(m["Destination"] == "/models" and pathlib.Path(m["Source"]).resolve() == model_path.parent.resolve()
                   and not m.get("RW", True) for m in inspected["Mounts"])
    if not mount_ok:
        raise ValueError("Server does not mount the verified model directory read-only")
    if http_json("/health", timeout=10).get("status") != "ok":
        raise ValueError("Model server is not ready")
    props = http_json("/props", timeout=10)
    if props.get("model_path") != "/models/" + MODEL_FILE:
        raise ValueError("Server reports an unexpected model path")
    if ALIAS not in [m["id"] for m in http_json("/v1/models", timeout=10)["data"]]:
        raise ValueError("Server reports an unexpected model alias")
    if props.get("total_slots") != 1:
        raise ValueError("Pilot expects one server slot")
    runtime["verified_sha256"] = MODEL_SHA
    runtime["model_bytes"] = model_path.stat().st_size
    runtime["server_properties"] = props
    runtime["gpu"] = command(["nvidia-smi", "--query-gpu=name,memory.total,driver_version", "--format=csv"])
    runtime["python"] = sys.version
    runtime["network_mode"] = inspected["HostConfig"]["NetworkMode"]
    runtime["endpoint"] = BASE_URL
    runtime["runtime_labels"] = inspected["Config"].get("Labels", {})
    return runtime


def recover():
    """Rebuild setup metadata from a verified existing server; no inference or restart."""
    print("Verifying the existing server and model before saving runtime.json...", flush=True)
    inspected = strict_json(command(["docker", "inspect", CONTAINER]))[0]
    verify_container(inspected)
    config = inspected["Config"]
    if (config.get("Labels") or {}).get("usb-me.purpose") != "nine-case-pilot":
        raise ValueError("Existing container is not labeled as this package's pilot server")
    digest = config["Image"]
    if not re.fullmatch(r"ghcr\.io/ggml-org/llama\.cpp@sha256:[0-9a-f]{64}", digest):
        raise ValueError("Existing server does not use a pinned official llama.cpp image digest")
    pin = ROOT / "llama-cpp-image.txt"
    if pin.exists() and pin.read_text().strip() != digest:
        raise ValueError("Existing server image differs from llama-cpp-image.txt; inspect before replacing the pin")
    mounts = [m for m in inspected["Mounts"] if m["Destination"] == "/models"]
    if len(mounts) != 1 or mounts[0].get("RW", True):
        raise ValueError("Expected exactly one read-only /models mount")
    model_path = pathlib.Path(mounts[0]["Source"]) / MODEL_FILE
    candidate = {"created_at": inspected["Created"], "recovered_at": utc_now(),
                 "container_id": inspected["Id"], "image_digest": digest,
                 "model_file": str(model_path.resolve()), "command": config["Cmd"]}
    # Use the same checksum, container, mount, health, model, and slot checks as a run.
    # Save nothing unless all checks succeed; do not invent metadata from defaults.
    verified = preflight(candidate)
    if not pin.exists():
        pin.write_text(digest + "\n", encoding="utf-8")
    save_json(ROOT / "runtime.json", verified)
    print("Model server ready. Setup record recovered. Next: python3 pilot.py run")
    return 0


def summarize(report):
    rows = []
    for tier in ("easy", "medium", "hard"):
        items = [r for r in report["results"] if r["difficulty"] == tier]
        auto = sum(r["auto_pass"] for r in items)
        reviewed = sum(r["human_review"] is not None for r in items)
        passes = sum(r["auto_pass"] and r["human_review"] is not None and r["human_review"]["passed"] for r in items)
        rows.append((tier, len(items), auto, reviewed, passes))
    return rows


def planned_tiers(report):
    # Old nine-case reports remain readable without relabeling them as 150-case runs.
    return report.get("planned_by_tier", {t: report.get("planned_cases", 9) // 3 for t in TIER_COUNTS})


def write_summary(directory, report):
    lines = ["# USB-Me latest completed results", "",
             "Run: `%s` · Dataset: `%s` · Planned cases: %d" % (directory.name, report.get("dataset_version", "legacy"), report.get("planned_cases", 9)),
             "", "Status: " + report["status"], "",
             "Automatic checks are provisional until speech and answer keys have been reviewed.", "",
             "| Difficulty | Automatic passes | Human-reviewed passes |",
             "|---|---:|---:|"]
    for tier, attempted, auto, reviewed, passed in summarize(report):
        count = planned_tiers(report)[tier]
        lines.append("| %s | %d/%d | %d/%d (%d reviewed) |" % (tier, auto, count, passed, count, reviewed))
    lines += ["", "[Full HTML report](runs/%s/report.html)" % directory.name,
              "", "[Full Markdown report](runs/%s/report.md)" % directory.name,
              "", "Review: `bash workflow.sh review` on Brev. Each run remains in its own folder.", ""]
    (ROOT / "RESULTS.md").write_text("\n".join(lines), encoding="utf-8")


def write_report(directory, report):
    save_json(directory / "results.json", report)
    lines = ["# USB-Me %s-case voice-assistant evaluation" % report.get("planned_cases", 9), "", "Status: " + report["status"], "",
             "Automated checks are provisional until speech and answer keys are reviewed. No real tools execute.", "",
             "| Tier | Attempted / planned | Auto checks passed | Human-reviewed | Reviewed passes |",
             "|---|---:|---:|---:|---:|"]
    for tier, attempted, auto, reviewed, passes in summarize(report):
        lines.append("| %s | %d / %d | %d | %d | %d |" % (tier, attempted, planned_tiers(report)[tier], auto, reviewed, passes))
    if report.get("error"):
        lines.extend(["", "Setup/run error: " + report["error"]])
    for item in report["results"]:
        lines.extend(["", "## " + item["id"] + ": " + item["title"], "",
                      "Request: " + item["input"]["user_request"], "",
                      "Automated checks: " + ("PASS (speech review needed)" if item["auto_pass"] else "FAIL"),
                      "", "Elapsed request time: %.3f seconds" % item["elapsed_seconds"], "",
                      "Expected structured fields:", "```json", json.dumps(item["expected"], indent=2), "```",
                      "Actual response:", "```json", json.dumps(item["actual"] if item["actual"] is not None else item.get("raw_content"), indent=2), "```"])
        lines.extend("- " + error for error in item["errors"])
        lines.extend(["", "Human review checks:"] + ["- " + check for check in item["human_checks"]])
        if item["human_review"]:
            lines.extend(["", "Review: " + json.dumps(item["human_review"], ensure_ascii=False)])
        if item.get("assistant_review"):
            lines.extend(["", "Assistant review (not human review): " + json.dumps(item["assistant_review"], ensure_ascii=False)])
    lines.extend(["", "These exposed development cases do not establish general accuracy or safety. They are independent next-decision checks, not full conversations, Swift integration tests, or iPhone/audio benchmarks.",
                  "Request times include HTTP and full generation, may include warm-up effects, and are not iPhone latency or time-to-first-token.", ""])
    (directory / "report.md").write_text("\n".join(lines), encoding="utf-8")
    render_report(directory, report)
    latest = ROOT / "runs" / "LATEST"
    if latest.exists() and latest.read_text().strip() == directory.name:
        write_summary(directory, report)


def run():
    dataset = load_cases()
    prompt = (ROOT / "system_prompt.txt").read_text(encoding="utf-8")
    run_id = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    directory = ROOT / "runs" / run_id
    directory.mkdir(parents=True)
    report = {"started_at": utc_now(), "status": "incomplete", "workflow_version": WORKFLOW_VERSION, "dataset_version": dataset["version"],
              "dataset_sha256": sha_file(ROOT / "cases.json"), "prompt_sha256": sha_file(ROOT / "system_prompt.txt"),
              "runner_sha256": sha_file(ROOT / "pilot.py"), "model_revision": MODEL_REV,
              "timeouts_seconds": 120, "retries": 0, "planned_cases": len(dataset["cases"]),
              "planned_by_tier": dict(collections.Counter(c["difficulty"] for c in dataset["cases"])), "results": []}
    save_json(directory / "dataset.json", dataset)
    (directory / "system_prompt.txt").write_text(prompt, encoding="utf-8")
    save_json(directory / "output_schema.json", SCHEMA)
    (directory / "pilot.py").write_bytes((ROOT / "pilot.py").read_bytes())
    write_report(directory, report)
    try:
        print("Verifying model checksum, container identity, and local endpoint...", flush=True)
        report["runtime"] = preflight()
        for index, case in enumerate(dataset["cases"], 1):
            payload = make_request(dataset, case, prompt)
            item = {k: case[k] for k in ("id", "difficulty", "title", "input", "expected", "human_checks")}
            item.update({k: case[k] for k in ("category", "coverage_key", "tags")})
            item["environment"] = dict(dataset["environment"], **case.get("environment", {}))
            item.update({"request": payload, "auto_pass": False, "human_review": None,
                         "actual": None, "raw_content": None, "errors": []})
            begin = time.perf_counter()
            try:
                response = http_json("/v1/chat/completions", payload)
                item["raw_response"] = response
                choice = response["choices"][0]
                item["raw_content"] = choice["message"]["content"]
                item["actual"], item["errors"] = grade(item["raw_content"], case["expected"])
                if choice.get("finish_reason") != "stop":
                    item["errors"].append("Generation did not finish normally: " + str(choice.get("finish_reason")))
                if choice["message"].get("tool_calls"):
                    item["errors"].append("Unexpected native tool call instead of the required proposal JSON")
            except urllib.error.HTTPError as exc:
                item["errors"].append("HTTP %s: %s" % (exc.code, exc.read().decode("utf-8", "replace")[:4000]))
                # Request-contract/auth failures invalidate the run; do not count them as model failures.
                if exc.code in (400, 401, 403, 404, 422):
                    item["harness_error"] = True
            except (urllib.error.URLError, TimeoutError, OSError) as exc:
                item["errors"].append("Request failed/timed out, no retry: " + str(exc))
            except (ValueError, KeyError, IndexError, TypeError) as exc:
                item["errors"].append("Malformed server response: " + str(exc))
                item["harness_error"] = True
            item["elapsed_seconds"] = time.perf_counter() - begin
            item["auto_pass"] = not item["errors"]
            report["results"].append(item)
            write_report(directory, report)
            print("[%d/%d] %s %-6s %-9s %.2fs — %s" % (index, len(dataset["cases"]), case["id"], case["difficulty"],
                  "AUTO PASS" if item["auto_pass"] else "FAIL", item["elapsed_seconds"], case["title"]), flush=True)
            if item.get("harness_error"):
                raise ValueError("Server/API configuration error; report is incomplete, not a model score")
        report["status"] = "model_run_complete_human_review_pending"
        report["finished_at"] = utc_now()
        write_report(directory, report)
        (ROOT / "runs" / "LATEST").write_text(run_id + "\n", encoding="utf-8")
        write_summary(directory, report)
    except (Exception, KeyboardInterrupt) as exc:
        report["error"] = str(exc) or "Interrupted"
        report["status"] = "incomplete"
        write_report(directory, report)
        print("Run incomplete: " + report["error"], file=sys.stderr)
        print("Saved partial report: " + str(directory / "report.md"))
        return 2
    print("\nSaved: " + str(directory / "report.md"))
    print("Next: python3 pilot.py review   (speech and answer-key review; no GPU requests)")
    return 0


def review(run_name=None):
    run_name = run_name or (ROOT / "runs" / "LATEST").read_text().strip()
    if pathlib.Path(run_name).name != run_name or run_name in (".", ".."):
        raise ValueError("--run must be a run directory name")
    directory = ROOT / "runs" / run_name
    report = strict_json((directory / "results.json").read_text(encoding="utf-8"))
    if len(report["results"]) != report.get("planned_cases", 9) or report["status"] == "incomplete":
        raise ValueError("Only complete runs can be reviewed/scored")
    reviewer = input("Reviewer name (Enter for %s): " % getpass.getuser()).strip() or getpass.getuser()
    print("Review the supplied answer key as well as the speech. Reject materially wrong or ambiguous labels.")
    for item in report["results"]:
        if item["human_review"] is not None:
            continue
        print("\n" + item["id"] + " — " + item["title"])
        print("Input:\n" + json.dumps(item["input"], indent=2))
        print("Environment:\n" + json.dumps(item.get("environment", item.get("request", {}).get("messages", [])), indent=2))
        print("Expected fields:\n" + json.dumps(item["expected"], indent=2))
        print("Actual:\n" + json.dumps(item["actual"] if item["actual"] is not None else item["raw_content"], indent=2))
        for check in item["human_checks"]:
            print(" • " + check)
        print("Automatic errors: " + json.dumps(item["errors"]))
        while True:
            answer = input("Are the label and ALL speech/behavior checks correct? [y/n/q]: ").strip().lower()
            if answer in ("y", "n", "q"):
                break
        if answer == "q":
            print("Review saved; run the review command again to resume.")
            return 0
        note = input("Review note (explain any failure or disputed label): ").strip()
        item["human_review"] = {"passed": answer == "y", "reviewer": reviewer, "at": utc_now(), "note": note}
        write_report(directory, report)
    report["status"] = "review_complete"
    write_report(directory, report)
    for tier, attempted, auto, reviewed, passed in summarize(report):
        total = planned_tiers(report)[tier]
        print("%s: %d/%d reviewed decision passes (%.1f%%)" % (tier, passed, total, 100 * passed / total))
    print("Development evaluation only. Detailed results: " + str(directory / "report.md"))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["run", "review", "validate", "recover"])
    parser.add_argument("--run", help="Run directory name to review; defaults to most recent completed run")
    args = parser.parse_args()
    try:
        if args.action == "validate":
            load_cases()
            print("Dataset structure valid: 50 easy + 50 medium + 50 hard = 150 unique cases. All ten tools covered. Model not run; labels still need human review.")
            return 0
        if args.action == "recover":
            return recover()
        return run() if args.action == "run" else review(args.run)
    except (Exception, KeyboardInterrupt) as exc:
        print("Error: " + (str(exc) or "Interrupted"), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
