#!/usr/bin/env bash
# Phase 1 physical-device feasibility benchmark.
#
# Builds the Release device app, installs it, sideloads the pinned models from ModelCache/ into the
# app's Documents/ModelImport/ (the app re-verifies size + SHA-256 before loading), launches the
# benchmark (-RunBenchmark), waits for the JSON report and copies it to Tests/Benchmarks/Results/.
#
# Usage: Scripts/benchmark_device.sh [--device <udid-or-coredevice-id>] [--skip-build] [--skip-models]
# Requires: iPhone connected, unlocked, trusted, Developer Mode on; a development team in App/project.yml.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUNDLE_ID="com.mouhamadmamane.voiceagent"
DEVICE=""
SKIP_BUILD=0
SKIP_MODELS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --skip-models) SKIP_MODELS=1; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }

if [[ -z "$DEVICE" ]]; then
  DEVICE="$(xcrun devicectl list devices 2>/dev/null | awk '/connected/ && /iPhone/ {print $(NF-3); exit}')"
  [[ -n "$DEVICE" ]] || { echo "No connected iPhone found (xcrun devicectl list devices)." >&2; exit 1; }
fi
UDID="$(xcrun devicectl device info details --device "$DEVICE" 2>/dev/null | awk '/ udid:/ {print $NF; exit}')"
log "Device $DEVICE (udid $UDID)"

APP="$ROOT/.build/xcode-device/Build/Products/Release-iphoneos/VoiceAgent.app"
if [[ $SKIP_BUILD == 0 ]]; then
  log "Building Release device app"
  xcodebuild -project App/VoiceAgent.xcodeproj -scheme VoiceAgent -configuration Release \
    -destination "platform=iOS,id=$UDID" -derivedDataPath .build/xcode-device -allowProvisioningUpdates build \
    | tail -3
fi
[[ -d "$APP" ]] || { echo "Missing $APP" >&2; exit 1; }

log "Installing"
xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null

if [[ $SKIP_MODELS == 0 ]]; then
  for file in ggml-base.en.bin ggml-silero-v6.2.0.bin NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf kokoro-v1_0.safetensors af_heart.safetensors; do
    [[ -f "ModelCache/$file" ]] || { echo "Missing ModelCache/$file — run Scripts/download_models.sh" >&2; exit 1; }
    log "Sideloading $file"
    xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
      --source "ModelCache/$file" --destination "Documents/ModelImport/$file" >/dev/null
  done
fi

log "Launching benchmark"
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE_ID" -RunBenchmark >/dev/null

OUT="$ROOT/Tests/Benchmarks/Results"
mkdir -p "$OUT/tmp"
log "Waiting for the report (the phone must stay unlocked; this takes several minutes)"
for _ in $(seq 1 180); do
  sleep 10
  if xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
      --source "Documents/BenchmarkReports/latest.json" --destination "$OUT/tmp/latest.json" >/dev/null 2>&1; then
    if [[ -s "$OUT/tmp/latest.json" ]] && python3 -c "import json,sys; d=json.load(open('$OUT/tmp/latest.json')); sys.exit(0 if d.get('finishedAt') else 1)" 2>/dev/null; then
      break
    fi
  fi
  if xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
      --source "Documents/BenchmarkReports/latest-error.txt" --destination "$OUT/tmp/latest-error.txt" >/dev/null 2>&1; then
    echo "Benchmark failed on device:" >&2; cat "$OUT/tmp/latest-error.txt" >&2; exit 1
  fi
done
[[ -s "$OUT/tmp/latest.json" ]] || { echo "Timed out waiting for the report" >&2; exit 1; }
STAMP="$(date +%Y%m%d-%H%M%S)"
MODEL="$(python3 -c "import json; print(json.load(open('$OUT/tmp/latest.json'))['environment']['deviceModel'])")"
cp "$OUT/tmp/latest.json" "$OUT/$MODEL-$STAMP.json"
log "Report: Tests/Benchmarks/Results/$MODEL-$STAMP.json"
python3 - "$OUT/$MODEL-$STAMP.json" <<'EOF'
import json, sys
report = json.load(open(sys.argv[1]))
env = report["environment"]
print(f"{env['deviceModel']}  {env['systemVersion']}  RAM {env['physicalMemoryGB']:.1f} GB")
for m in report["metrics"]:
    print(f"  {m['stage'] + '.' + m['name']:42s} p50 {m['p50']:10.1f}  p95 {m['p95']:10.1f} {m['unit']}")
print(f"  peak footprint {report['peakFootprintMB']:.0f} MB; thermal {' -> '.join(report['thermalStates'])}")
for note in report.get("notes", []): print("  note:", note)
for error in report.get("errors", []): print("  ERROR:", error)
EOF
