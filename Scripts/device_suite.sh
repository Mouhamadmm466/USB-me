#!/usr/bin/env bash
# Runs the on-device verification suite unattended: voice self-test → benchmark → full agent
# evaluation. Waits for the iPhone to be unlocked before each step and relaunches the current
# step when the phone was locked in the middle (the evaluation resumes where it stopped).
#
# Usage: Scripts/device_suite.sh [--device ID] [--run NAME] [--skip-selftest] [--skip-benchmark] [--skip-eval]
# The Profile build must already be installed (Scripts/benchmark_device.sh or eval_device.sh
# build and install it). Results land in Tests/Benchmarks/Results/tmp/ and
# Tests/AgentEval/Results/<run>/.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUNDLE_ID="com.mouhamadmamane.voiceagent"
DEVICE=""
RUN="device-full-$(date +%Y%m%d)"
DO_SELFTEST=1; DO_BENCHMARK=1; DO_EVAL=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --run) RUN="$2"; shift 2 ;;
    --skip-selftest) DO_SELFTEST=0; shift ;;
    --skip-benchmark) DO_BENCHMARK=0; shift ;;
    --skip-eval) DO_EVAL=0; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
if [[ -z "$DEVICE" ]]; then
  DEVICE="$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && (/connected/ || /available/) {print $(NF-3); exit}')"
fi
[[ -n "$DEVICE" ]] || { echo "No iPhone found (xcrun devicectl list devices)." >&2; exit 1; }

log() { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*"; }
unlocked() { xcrun devicectl device info lockState --device "$DEVICE" 2>/dev/null | grep -q "passcodeRequired: false"; }
running() { xcrun devicectl device info processes --device "$DEVICE" 2>/dev/null | grep -q "VoiceAgent.app/VoiceAgent"; }
# Retries until iOS accepts the launch (it refuses while the phone is locked).
launch() {
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE_ID" -- "$@" 2>&1 | grep -q "Launched application"; then
      return 0
    fi
    log "  launch refused (phone locked?) — retrying"
    wait_unlocked
    sleep 2
  done
  return 1
}
fetch() { xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --source "$1" --destination "$2" >/dev/null 2>&1; }
wait_unlocked() {
  if ! unlocked; then log "waiting for the iPhone to be unlocked"; fi
  until unlocked; do sleep 15; done
}

# Runs one step: launch with args, then poll `done_check` until it succeeds. If the app is no
# longer running (phone locked, app killed) the step is relaunched once the phone is unlocked.
run_step() {
  local name="$1" done_check="$2"; shift 2
  local started
  wait_unlocked
  log "$name: launching"
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; export STEP_STARTED="$started"
  launch "$@"
  local idle=0
  while true; do
    sleep 20
    if eval "$done_check"; then log "$name: finished"; return 0; fi
    if running; then idle=0; continue; fi
    idle=$((idle + 1))
    if (( idle >= 2 )); then
      log "$name: app not running (phone locked?) — relaunching when unlocked"
      wait_unlocked
      launch "$@"
      idle=0
    fi
  done
}

TMP="$ROOT/Tests/Benchmarks/Results/tmp"
mkdir -p "$TMP/selftest"

if (( DO_SELFTEST )); then
  selftest_done() {
    fetch Documents/SelfTest/latest.json "$TMP/selftest/latest.json" &&
      python3 -c "import json,sys,os; d=json.load(open('$TMP/selftest/latest.json')); sys.exit(0 if d.get('finishedAt') and d['startedAt'] >= os.environ['STEP_STARTED'] else 1)" 2>/dev/null
  }
  run_step "voice self-test" selftest_done -VoiceSelfTest
  python3 - "$TMP/selftest/latest.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print("  error:", d.get("error"))
for s in d["steps"]:
    print(f'  {"PASS" if s["passed"] else "FAIL"} {s["name"]}: {s["detail"]} | heard: {s.get("heard")} | said: {(s.get("assistant") or "")[:140]}')
for k, v in sorted(d.get("latencies", {}).items()):
    print(f'  {k:30s} p50 {v["p50"]:7.0f}  p95 {v["p95"]:7.0f}  n={v["count"]}')
print("  barge-ins:", d.get("bargeIns"))
PY
fi

if (( DO_BENCHMARK )); then
  benchmark_done() {
    fetch Documents/BenchmarkReports/latest.json "$TMP/latest.json" &&
      python3 -c "import json,sys,os; d=json.load(open('$TMP/latest.json')); sys.exit(0 if d.get('finishedAt') and d['startedAt'] >= os.environ['STEP_STARTED'] else 1)" 2>/dev/null
  }
  run_step "benchmark" benchmark_done -RunBenchmark
  cp "$TMP/latest.json" "$ROOT/Tests/Benchmarks/Results/iPhone-$(date +%Y%m%d-%H%M%S).json"
fi

if (( DO_EVAL )); then
  OUT="$ROOT/Tests/AgentEval/Results/$RUN"
  mkdir -p "$OUT"
  xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source Tests/AgentEval/Cases --destination Documents/Eval/Cases >/dev/null
  xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source Tests/AgentEval/Fixtures --destination Documents/Eval/Fixtures >/dev/null
  eval_done() {
    fetch "Documents/Eval/Runs/$RUN/progress.json" "$OUT/progress.json" || return 1
    python3 -c "
import json; p = json.load(open('$OUT/progress.json'))
print(f'    {p[\"completed\"]}/{p[\"total\"]}  {p.get(\"secondsPerCase\", 0):.1f} s/case  thermal={p.get(\"thermalState\")}')" || true
    grep -q '"finished":true' "$OUT/progress.json"
  }
  run_step "evaluation ($RUN)" eval_done -RunEval -EvalRun "$RUN"
  fetch "Documents/Eval/Runs/$RUN/observations.jsonl" "$OUT/observations.jsonl"
  fetch "Documents/Eval/Runs/$RUN/run.json" "$OUT/run.json"
  swift run -c release agent-eval score --run "$OUT" | head -60
fi
log "suite finished"
