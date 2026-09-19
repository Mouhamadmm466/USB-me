# Device matrix

## Supported devices

| Class | Devices | RAM | Status |
|---|---|---|---|
| Supported | iPhone 15 Pro / 15 Pro Max (A17 Pro) | 8 GB | Primary target; benchmark pending (see below) |
| Supported | iPhone 16 / 16 Plus / 16 Pro / 16 Pro Max / 16e | 8 GB | Expected to work (same memory class, newer GPU) — not yet measured |
| Supported | iPhone 17 / 17 Pro / 17 Pro Max / Air | 8–12 GB | Expected to work — not yet measured |
| Not supported | iPhone 15 / 15 Plus and earlier | ≤ 6 GB | Excluded via `UIRequiredDeviceCapabilities: iphone-performance-gaming-tier` (A17 Pro/M-class and later) |
| Development only | iOS Simulator (x86_64 and arm64) | — | No TTS (MLX unsupported); LLM/ASR on CPU |

Minimums: iOS 18.0; ≥ 4 GB free storage for models; the app checks physical memory (≥ 7.5 GB)
before enabling model downloads.

## Memory budget (expected; to be confirmed on device)

| Component | On disk | Resident (estimate) |
|---|---|---|
| Nemotron 3 Nano 4B Q4_K_M (mmap, Metal) | 2.84 GB | weights mapped; KV cache (4 attention layers, 4K ctx) ≈ 64 MB; Mamba-2 state ≈ 84 MB; prefix snapshot ≈ 100 MB |
| Whisper base.en | 148 MB | ≈ 200–300 MB incl. compute buffers |
| Silero VAD | 0.9 MB | < 5 MB |
| Kokoro 82M (fp32 safetensors) + voice | 328 MB | ≈ 400–600 MB incl. MLX buffers (cache capped at 64 MB) |

## Measured results

### Build Mac (Intel Core i7-1068NG7, 4 cores, CPU only — not a supported runtime, used for evaluation)

Filled in from `agent-eval` runs; see `Docs/EVALUATION.md`.

### iPhone 15 Pro (iPhone16,1)

_Pending: the device was not connected during this build session. Run `Scripts/benchmark_device.sh`
with the phone connected and unlocked; results are written to `Tests/Benchmarks/Results/` and this
table is updated from the JSON report._

| Metric (P50 / P95) | Target (PRD §13) | Measured |
|---|---|---|
| End of speech → first audible response | < 1.5 s (poor > 2.5 s) | — |
| Endpoint → final transcript | < 500 ms | — |
| Nemotron → structured result | < 750 ms | — |
| TTS time to first audio (short chunk) | < 300–500 ms | — |
| Cold start (all models) | measured separately | — |
| Peak memory footprint | no jetsam | — |
| Thermal state over 10 turns | no sustained critical | — |
| Battery delta over benchmark | — | — |
