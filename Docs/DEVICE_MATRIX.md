# Device matrix

## Supported devices

| Class | Devices | RAM | Status |
|---|---|---|---|
| Supported, measured | iPhone 15 Pro / 15 Pro Max (A17 Pro) | 8 GB | Primary target. Benchmarked (below) |
| Supported | iPhone 16 / 16 Plus / 16 Pro / 16 Pro Max / 16e | 8 GB | Expected to work (same memory class, newer GPU). Not yet measured |
| Supported | iPhone 17 / 17 Pro / 17 Pro Max / Air | 8–12 GB | Expected to work. Not yet measured |
| Not supported | iPhone 15 / 15 Plus and earlier | ≤ 6 GB | Excluded via `UIRequiredDeviceCapabilities: iphone-performance-gaming-tier` (A17 Pro/M-class and later) |
| Development only | iOS Simulator (x86_64 and arm64) | — | No TTS (MLX unsupported); LLM/ASR on CPU |

Minimums: iOS 18.0; ≥ 4 GB free storage for models; the app checks physical memory (≥ 7.5 GB)
before enabling model downloads.

## iPhone 15 Pro (iPhone16,1), iOS 26.6.1 — measured

Reports: `Tests/Benchmarks/Results/iPhone16,1-*.json` (produced by `Scripts/benchmark_device.sh`;
the app's `-RunBenchmark` mode runs the exact pinned models after re-verifying their SHA-256).
Numbers below are from run 8 (`iPhone16,1-run8-primed.json`, 2026-09-19, the shipping
configuration), cold start from run 1 (`iPhone16,1-run1-coldinstall.json`, first launch after
install). Free team build with the Increased Memory Limit entitlement granted.

### PRD §13 budget

| Metric (P50 / P95) | Target | Measured | Notes |
|---|---|---|---|
| Endpoint → final transcript | < 500 ms | **196 / 199 ms** | Whisper base.en on Metal, 3.2 s utterance (RTF 19×) |
| Nemotron → complete structured result | < 750 ms | **1285 / 1781 ms** (6 commands) | Context primed during speech; 238 ms prompt + ~77 ms per sampled token. Not met: see "LLM latency" |
| TTS time to first audio (first chunk) | < 300–500 ms | **365 / 443 ms** | Kokoro 82M on MLX; first chunk ends at the first clause |
| Endpoint → first audio, longest command | — | **2416 / 2441 ms** | "Text Alex that I will be 20 minutes late" (15 decode calls) |
| End of speech → first audio | < 1.5 s preferred, > 2.5 s poor | ≈ 2.9 s for the longest command (derived: endpoint silence + line above) | Endpoint silence is 0.5 s when the partial transcript is stable, else 0.7 s. Short commands need fewer decode calls; per-command end-to-end numbers: see the per-utterance table below when present |
| Peak memory footprint (all models resident) | no jetsam | **1.27 GB** (6.1 GB available at start) | Model weights are memory-mapped and not counted in the footprint |
| Thermal | no sustained critical | nominal → fair during benchmark | Sustained multi-hour load: see the device evaluation run in `Docs/EVALUATION.md` |
| False consequential executions | 0 | 0 | Release safety suite, `Docs/EVALUATION.md` |

### Cold vs warm start

| Stage | First launch after install | Later launches |
|---|---|---|
| Whisper load | 17.5 s (Metal shader compile, page-in) | 0.28 s |
| Nemotron load | 23.5 s + 17.7 s prefix evaluation | 4.3 s + 0.16 s prefix state load (disk cache) |
| Kokoro load + warm-up | 5.6 s | 1.0 s |

The first launch also imports and SHA-256-verifies 3.3 GB of models (once).

### LLM latency: where the time goes

Nemotron 3 Nano 4B is a hybrid Mamba-2/attention model (42 layers, 4 attention). All 43 layers run
on the GPU (`graph splits = 2`: only the token-embedding lookup is on the CPU); llama.cpp's Metal
backend has native `ssm_scan`/`ssm_conv` kernels, so nothing falls back to the CPU.

Cost of one `llama_decode` call by number of tokens (A17 Pro, median of 3):

| Tokens per call | ms (n_rs_seq = 0, shipping) | ms (n_rs_seq = 5) |
|---:|---:|---:|
| 1 | 77 | 76 |
| 2 | 100 | 108 |
| 3 | 138 | 156 |
| 4 | 176 | 205 |
| 5 | 221 | 263 |
| 6 | 248 | 305 |
| 7 | 294 | 356 |
| 8 | 326 | 391 |
| 9 | 210 | 268 |
| 12 | 217 | 273 |
| 16 | 227 | 284 |
| 24 | 241 | 298 |
| 32 | 261 | 316 |
| 48 | 446 | 514 |

Batches of 2–8 tokens use llama.cpp's small-batch mat-vec kernels, which on this GPU cost almost
linearly more per token; from 9 tokens the mat-mat kernels cost about the same up to 32.
Consequences, all measured:

| Change | Structured result P50 | Decision |
|---|---|---|
| Baseline (one decode per token) | 2105 ms (run 3) | — |
| Grammar-forced text in the same call as the sampled token; `requires_confirmation` fixed by the grammar | 1646 ms (run 4) | kept |
| Prompt + reply opening `{"type":"` in one call | 1498 ms (run 5, speculation off) | kept |
| Prompt-lookup speculative decoding (copy argument values from the utterance, verify in the same call, roll back Mamba state with `n_rs_seq`) | 1725–1752 ms (runs 5–7) vs 1498–1508 ms without | **off by default**: drafts make 2–8 token calls and snapshots add ~20%; halves decode calls on CPU hosts |
| Turn context evaluated at speech onset (`prime`), only the utterance after the endpoint | **1285 ms** (run 8) vs 1508 ms unprimed | kept |

### Memory budget (measured where noted)

| Component | On disk | Resident |
|---|---|---|
| Nemotron 3 Nano 4B Q4_K_M (mmap, Metal) | 2.84 GB | weights mapped (not in footprint); KV cache 64 MB (4 attention layers × 4K ctx); Mamba-2 state 81 MB; compute buffers 287 MB (GPU) + 16 MB (CPU); prefix snapshot ≈ 120 MB |
| Whisper base.en | 148 MB | ≈ 200–300 MB incl. compute buffers |
| Silero VAD | 0.9 MB | < 5 MB |
| Kokoro 82M + af_heart voice | 328 MB | ≈ 400–600 MB incl. MLX buffers (cache capped at 64 MB) |
| **All resident (measured peak)** | 3.3 GB | **1.27 GB** footprint (1.74 GB with speculation's `n_rs_seq = 5`) |

## Build Mac (Intel Core i7-1068NG7, 4 cores, CPU only)

Not a supported runtime. Used for unit tests, ASR/VAD fixture tests and evaluation runs of the real
model on the CPU. A turn takes 5–40 s depending on load, so full evaluation runs use the phone
(`Scripts/eval_device.sh`).
