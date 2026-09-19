#!/usr/bin/env bash
# Runs the agent evaluation suite on a connected iPhone and scores it on the Mac.
#
# The device app's -RunEval mode runs every case through the real agent pipeline with the pinned
# Nemotron model on Metal (the production runtime and prompt) and the harness's fake contacts,
# calendars and messages. Observations are appended on the phone as cases finish, so a run that
# is interrupted (phone locked, app killed) resumes where it stopped when relaunched with the same
# --run name.
#
# Usage: Scripts/eval_device.sh [--device ID] [--run NAME] [--limit N] [--category NAME]
#                               [--skip-build] [--skip-copy]
# Requires: iPhone connected, unlocked, trusted, Developer Mode on; models imported
# (Scripts/benchmark_device.sh sideloads them). Keep the app in the foreground while it runs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUNDLE_ID="com.mouhamadmamane.voiceagent"
DEVICE=""
RUN="device-$(date +%Y%m%d-%H%M)"
LIMIT=""
CATEGORY=""
SKIP_BUILD=0
SKIP_COPY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --run) RUN="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --category) CATEGORY="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --skip-copy) SKIP_COPY=1; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
container() { xcrun devicectl device copy "$1" --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" "${@:2}"; }

if [[ -z "$DEVICE" ]]; then
  DEVICE="$(xcrun devicectl list devices 2>/dev/null | awk '/connected/ && /iPhone/ {print $(NF-3); exit}')"
  [[ -n "$DEVICE" ]] || { echo "No connected iPhone found (xcrun devicectl list devices)." >&2; exit 1; }
fi

APP="$ROOT/.build/xcode-device/Build/Products/Release-iphoneos/VoiceAgent.app"
if [[ $SKIP_BUILD == 0 ]]; then
  UDID="$(xcrun devicectl device info details --device "$DEVICE" 2>/dev/null | awk '/ udid:/ {print $NF; exit}')"
  log "Building Release device app"
  xcodebuild -project App/VoiceAgent.xcodeproj -scheme VoiceAgent -configuration Release \
    -destination "platform=iOS,id=$UDID" -derivedDataPath .build/xcode-device -allowProvisioningUpdates build | tail -3
  log "Installing"
  xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null
fi

if [[ $SKIP_COPY == 0 ]]; then
  log "Copying cases and fixtures"
  container to --source Tests/AgentEval/Cases --destination Documents/Eval/Cases >/dev/null
  container to --source Tests/AgentEval/Fixtures --destination Documents/Eval/Fixtures >/dev/null
fi

ARGS=(-RunEval -EvalRun "$RUN")
[[ -n "$LIMIT" ]] && ARGS+=(-EvalLimit "$LIMIT")
[[ -n "$CATEGORY" ]] && ARGS+=(-EvalCategory "$CATEGORY")
log "Launching run '$RUN' ${LIMIT:+(limit $LIMIT)} ${CATEGORY:+(category $CATEGORY)}"
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE_ID" -- "${ARGS[@]}" >/dev/null

OUT="$ROOT/Tests/AgentEval/Results/$RUN"
mkdir -p "$OUT"
REMOTE="Documents/Eval/Runs/$RUN"
while true; do
  sleep 30
  if container from --source "$REMOTE/error.txt" --destination "$OUT/error.txt" >/dev/null 2>&1; then
    echo "Run failed on the device:" >&2; cat "$OUT/error.txt" >&2; exit 1
  fi
  container from --source "$REMOTE/progress.json" --destination "$OUT/progress.json" >/dev/null 2>&1 || continue
  python3 - "$OUT/progress.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
left = (p["total"] - p["completed"]) * p.get("secondsPerCase", 0) / 60
print(f'  {p["completed"]}/{p["total"]} cases  {p.get("secondsPerCase", 0):.1f} s/case  ~{left:.0f} min left  thermal={p.get("thermalState")}', flush=True)
PY
  if grep -q '"finished":true' "$OUT/progress.json"; then break; fi
done

log "Copying observations"
container from --source "$REMOTE/observations.jsonl" --destination "$OUT/observations.jsonl" >/dev/null
container from --source "$REMOTE/run.json" --destination "$OUT/run.json" >/dev/null
log "Scoring"
swift run -c release agent-eval score --run "$OUT"
