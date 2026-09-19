#!/usr/bin/env bash
# Runs the agent evaluation suite against the real Nemotron model (CPU on Macs without Apple GPUs).
# Results: Tests/AgentEval/Results/<run>/ (per-case JSONL, report.md, report.json) + latest.md.
# Usage: Scripts/run_agent_eval.sh [--limit N] [--category NAME] [--tag TAG] [--resume RUN_DIR] [--threads N]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MODEL="$ROOT/ModelCache/NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf"
[[ -f "$MODEL" ]] || { echo "Model missing: run Scripts/download_models.sh --pack nemotron-3-nano-4b-q4_k_m" >&2; exit 1; }
swift build -c release --product agent-eval
exec "$ROOT/.build/release/agent-eval" run \
  --cases "$ROOT/Tests/AgentEval/Cases" \
  --fixtures "$ROOT/Tests/AgentEval/Fixtures" \
  --model "$MODEL" \
  --state-cache "$ROOT/ModelCache/llm-state" \
  --output "$ROOT/Tests/AgentEval/Results" \
  "$@"
