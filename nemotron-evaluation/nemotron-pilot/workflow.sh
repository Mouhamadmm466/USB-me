#!/usr/bin/env bash
# Run from any directory on the existing Brev VM.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
action="${1:-run}"
if [ "$#" -gt 0 ]; then shift; fi
case "$action" in
  run)
    if [ "$#" -gt 0 ]; then
      echo 'Usage: bash workflow.sh run' >&2
      exit 2
    fi
    command -v flock >/dev/null || { echo 'Run the workflow on the Linux Brev VM (flock is required).' >&2; exit 1; }
    if [ "${USB_ME_LOCK_HELD:-0}" != 1 ]; then
      exec 9>"${USB_ME_WORKFLOW_LOCK:-$HOME/.usb-me-workflow.lock}"
      flock -n 9 || { echo 'Another workflow run is active. Wait for it to finish before running again.' >&2; exit 1; }
    fi
    bash start_model.sh
    python3 pilot.py run
    python3 viewer.py report
    ;;
  cases) python3 viewer.py cases "$@" ;;
  validate) python3 pilot.py validate ;;
  report) python3 viewer.py report "$@" ;;
  review) python3 pilot.py review "$@" ;;
  status)
    docker inspect --format 'Status={{.State.Status}} Image={{.Config.Image}} Network={{.HostConfig.NetworkMode}}' usb-me-pilot-server
    curl --noproxy '*' --fail --show-error --silent --max-time 5 http://127.0.0.1:8080/health
    printf '\n'
    ;;
  *)
    echo 'Usage: bash workflow.sh [run|validate|cases|report|review|status]' >&2
    exit 2
    ;;
esac
