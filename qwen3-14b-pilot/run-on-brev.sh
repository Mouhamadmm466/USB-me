#!/usr/bin/env bash
# Run from your Mac. The model and all inference remain on the existing Brev VM.
set -euo pipefail
if [ "$(uname -s)" = Darwin ]; then export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"; fi
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
LOCAL_WORKFLOW="$PWD"
INSTANCE='usb-me-nemotron'
REMOTE_DIR='/home/ubuntu/qwen3-14b-pilot'
ACTION="${1:-run}"

fetch_results() {
  mkdir -p "$LOCAL_WORKFLOW/runs"
  scp -q -r "$INSTANCE:$REMOTE_DIR/runs/." "$LOCAL_WORKFLOW/runs/"
  scp -q "$INSTANCE:$REMOTE_DIR/runtime.json" "$INSTANCE:$REMOTE_DIR/llama-cpp-image.txt" "$INSTANCE:$REMOTE_DIR/RESULTS.md" "$LOCAL_WORKFLOW/"
  if [ -f runs/LATEST ]; then
    python3 viewer.py report
    echo "Local report: $LOCAL_WORKFLOW/runs/$(cat runs/LATEST)/report.html"
  fi
}

case "$ACTION" in
  cases)
    python3 viewer.py cases
    if [ "$(uname -s)" = Darwin ]; then open "$LOCAL_WORKFLOW/tests.html"; fi
    exit 0
    ;;
  report)
    python3 viewer.py report
    if [ "$(uname -s)" = Darwin ]; then open "$LOCAL_WORKFLOW/runs/$(cat runs/LATEST)/report.html"; fi
    exit 0
    ;;
  run|deploy|review|fetch|status) ;;
  *) echo 'Usage: bash run-on-brev.sh [run|deploy|cases|report|review|fetch|status]' >&2; exit 2 ;;
esac

for required in brev ssh scp python3 tar; do
  command -v "$required" >/dev/null || { echo "Missing $required on this Mac." >&2; exit 1; }
done

if [ "$ACTION" = run ] || [ "$ACTION" = deploy ]; then
  python3 pilot.py validate
  python3 viewer.py cases
fi
if [ "$ACTION" = run ]; then
  echo "Starting/reusing your existing Brev environment: $INSTANCE"
  if start_output="$(brev start "$INSTANCE" 2>&1)"; then
    printf '%s\n' "$start_output"
  elif [[ "$start_output" == *'Instance is not stopped status=RUNNING'* ]]; then
    echo 'The existing environment is already running.'
  else
    printf '%s\n' "$start_output" >&2
    exit 1
  fi
fi
brev refresh

case "$ACTION" in
  run|deploy)
    package_dir="$(mktemp -d "${TMPDIR:-/tmp}/usb-me-workflow.XXXXXX")"
    trap 'rm -f "$package_dir/workflow.tar.gz"; rmdir "$package_dir"' EXIT
    COPYFILE_DISABLE=1 tar --format ustar -czf "$package_dir/workflow.tar.gz" \
      pilot.py viewer.py cases.json system_prompt.txt start_model.sh workflow.sh \
      qwen_test_instructions.md VALIDATION.md RESULTS.md COVERAGE.md TESTS.md tests.html checks datasets .gitignore
    # Hold the same lock as direct VM runs before changing any deployed source.
    run_status=0
    if [ "$ACTION" = deploy ]; then
      # Deliberately no setup, Docker, health check, or inference on this path.
      ssh -o BatchMode=yes -o ConnectTimeout=20 "$INSTANCE" \
        'set -eu; mkdir -p /home/ubuntu/qwen3-14b-pilot; cd /home/ubuntu/qwen3-14b-pilot; exec 9>/home/ubuntu/.usb-me-workflow.lock; flock -n 9 || { echo "Another workflow is running." >&2; exit 1; }; tar -xzf -; python3 pilot.py validate; python3 viewer.py cases' < "$package_dir/workflow.tar.gz"
      echo 'Workflow deployed and validated. No model requests were made. Start it yourself with bash workflow.sh run on Brev.'
      exit 0
    fi
    ssh -o BatchMode=yes -o ConnectTimeout=20 "$INSTANCE" \
      'set -eu; mkdir -p /home/ubuntu/qwen3-14b-pilot; cd /home/ubuntu/qwen3-14b-pilot; exec 9>/home/ubuntu/.usb-me-workflow.lock; flock -n 9 || { echo "Another workflow is running." >&2; exit 1; }; tar -xzf -; USB_ME_LOCK_HELD=1 bash workflow.sh run' < "$package_dir/workflow.tar.gz" || run_status=$?
    fetch_results || { echo 'Results could not be copied. Retry: bash run-on-brev.sh fetch' >&2; exit 1; }
    if [ "$run_status" -ne 0 ]; then
      echo 'Workflow did not complete. Read the saved diagnostics above; no successful score is claimed.' >&2
      exit "$run_status"
    fi
    echo 'Run complete. View results: bash run-on-brev.sh report'
    ;;
  review)
    ssh -t "$INSTANCE" 'cd /home/ubuntu/qwen3-14b-pilot && bash workflow.sh review'
    fetch_results
    ;;
  fetch) fetch_results ;;
  status)
    brev ls
    ssh -o BatchMode=yes -o ConnectTimeout=20 "$INSTANCE" 'cd /home/ubuntu/qwen3-14b-pilot && bash workflow.sh status'
    ;;
esac
