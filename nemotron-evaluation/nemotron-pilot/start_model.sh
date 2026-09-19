#!/usr/bin/env bash
# Run this on the already-created Brev GPU VM, not on your Mac.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
PILOT_DIR="$PWD"
CONTAINER='usb-me-pilot-server'
PILOT_IMAGE='ghcr.io/ggml-org/llama.cpp@sha256:131a7be5d90d6df75f32ffad405d71e354e9bdba806264b6a905339283925b85'
MODEL_NAME='NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf'
MODEL_REV='1260a7780236524372acab3fdff3da563b611a2c'
MODEL_SHA='be5d9a656a51922f24f1f09a759cebb694e1f5d9728bf0ef9f8c972c5a0b5ef2'
SERVER_ARGS=(--model "/models/$MODEL_NAME" --alias usb-me-nemotron-4b-q4km
  --n-gpu-layers 999 --ctx-size 4096 --parallel 1
  --jinja --reasoning off --host 127.0.0.1 --port 8080)
if [ "$(uname -s)" != 'Linux' ]; then
  echo 'Run setup on the existing Linux Brev GPU VM. Host networking is required by this workflow.' >&2
  exit 1
fi
for required in python3 docker nvidia-smi curl sha256sum; do
  command -v "$required" >/dev/null || { echo "Missing $required. Run in the Brev GPU VM with Docker support." >&2; exit 1; }
done
nvidia-smi
docker info >/dev/null
python3 pilot.py validate
if [ -e llama-cpp-image.txt ] && [ "$(cat llama-cpp-image.txt)" != "$PILOT_IMAGE" ]; then
  echo 'The saved image pin differs from this workflow runtime. Archive the old workflow before rebuilding it.' >&2
  exit 1
fi

show_server_error() {
  docker inspect --format 'Status={{.State.Status}} ExitCode={{.State.ExitCode}} Error={{.State.Error}}' usb-me-pilot-server >&2 || true
  docker logs --tail 80 usb-me-pilot-server >&2 || true
}

wait_for_server() {
  echo 'Waiting for the pilot model server (up to 60 readiness checks, 5 seconds apart)...'
  for attempt in $(seq 1 60); do
    # Check this container before checking the port; another server may own port 8080.
    if [ "$(docker inspect --format '{{.State.Running}}' usb-me-pilot-server 2>/dev/null || true)" != 'true' ]; then
      show_server_error
      echo 'Pilot server stopped during startup. No tests were run. Share the error and logs above.' >&2
      return 1
    fi
    if curl --noproxy '*' --fail --silent --max-time 3 http://127.0.0.1:8080/health |
        python3 -c 'import json, sys; sys.exit(0 if json.load(sys.stdin).get("status") == "ok" else 1)' 2>/dev/null; then
      # Derive identity from Docker and verify the actual model, not just the health response.
      if python3 pilot.py recover; then
        return 0
      fi
      show_server_error
      echo 'Readiness succeeded but model verification failed. No tests were run. Share the error above.' >&2
      return 1
    fi
    if [ $((attempt % 6)) -eq 0 ]; then
      echo 'Still waiting for the model to finish loading...'
    fi
    sleep 5
  done
  show_server_error
  echo 'The pilot server is still not ready. No tests were run. Share the status and logs above.' >&2
  return 1
}

if docker inspect "$CONTAINER" >/dev/null 2>&1; then
  if ! docker inspect "$CONTAINER" | python3 -c '
import json, sys
container = json.load(sys.stdin)[0]
config = container["Config"]
host = container["HostConfig"]
matches = ((config.get("Labels") or {}).get("usb-me.purpose") == "nine-case-pilot"
           and config["Image"] == sys.argv[1]
           and config.get("Cmd") == sys.argv[2:]
           and host.get("NetworkMode") == "host"
           and not host.get("PortBindings"))
sys.exit(0 if matches else 1)
' "$PILOT_IMAGE" "${SERVER_ARGS[@]}"; then
    show_server_error
    echo 'The existing pilot container has different settings. Archive/replace that container before rebuilding; this command will not remove it.' >&2
    exit 1
  fi
  server_state="$(docker inspect --format '{{.State.Status}}' usb-me-pilot-server)"
  case "$server_state" in
    running) echo 'Using the existing running pilot container.' ;;
    created|exited)
      echo 'Starting the existing pilot container...'
      if ! docker start usb-me-pilot-server; then
        show_server_error
        echo 'Pilot container could not start. If port 8080 is occupied by your earlier usb-me-nemotron-server, stop that server first.' >&2
        exit 1
      fi
      ;;
    *)
      show_server_error
      echo 'The container must be running, created, or exited to use this recovery. Inspect its state before continuing.' >&2
      exit 1
      ;;
  esac
  wait_for_server
  exit 0
fi

# Reuse the location from the earlier setup instructions if its model already exists.
EARLIER_MODEL_DIR='/home/ubuntu/workspace/usb-me-nemotron/models'
if [ -f "$EARLIER_MODEL_DIR/$MODEL_NAME" ]; then
  MODEL_DIR="$EARLIER_MODEL_DIR"
else
  MODEL_DIR="$PILOT_DIR/models"
fi
mkdir -p "$MODEL_DIR"
if [ -f "$MODEL_DIR/$MODEL_NAME" ]; then
  printf '%s  %s\n' "$MODEL_SHA" "$MODEL_DIR/$MODEL_NAME" | sha256sum --check
else
  echo 'Downloading the exact PRD-pinned model (about 2.84 GB)...'
  curl --fail --location --retry 3 --continue-at - \
    --output "$MODEL_DIR/$MODEL_NAME.part" \
    "https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-4B-GGUF/resolve/$MODEL_REV/$MODEL_NAME"
  printf '%s  %s\n' "$MODEL_SHA" "$MODEL_DIR/$MODEL_NAME.part" | sha256sum --check
  mv -- "$MODEL_DIR/$MODEL_NAME.part" "$MODEL_DIR/$MODEL_NAME"
fi

# This exact CUDA build was verified loading the model on the existing Brev VM.
# Pull it only when absent; never resolve a moving tag during a rerun.
if ! docker image inspect "$PILOT_IMAGE" >/dev/null 2>&1; then
  docker pull "$PILOT_IMAGE"
fi
if ! docker run --detach --gpus all \
  --name "$CONTAINER" \
  --label usb-me.purpose=nine-case-pilot \
  --network host \
  -v "$MODEL_DIR:/models:ro" \
  "$PILOT_IMAGE" \
  "${SERVER_ARGS[@]}"; then
  show_server_error
  echo 'Pilot container could not start. Share the error above; if port 8080 is occupied by your earlier usb-me-nemotron-server, stop that server first.' >&2
  exit 1
fi

wait_for_server
