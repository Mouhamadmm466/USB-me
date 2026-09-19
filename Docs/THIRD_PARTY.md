# Third-party components and licenses

Every runtime and model is pinned. Update only through a reviewed change that re-runs the
regression suites (unit tests, `agent-eval`, device benchmark).

## Runtimes and libraries

| Component | Version / revision | License | How it is obtained |
|---|---|---|---|
| llama.cpp (ggml) | tag `b11046`, commit `60081bb2b5b3294165a4d67c5cbeebe74c868014` | MIT | Official release `llama-b11046-xcframework.zip` (SHA-256 `b6c46399…49938`) for iOS device + macOS; iOS-simulator slice built from the same commit with the official `build-xcframework.sh ios-sim` (the release omits it). `Scripts/bootstrap_dependencies.sh` |
| whisper.cpp (ggml) | `v1.9.4` = build `b5130` | MIT | Official release `whisper-b5130-xcframework.zip` (SHA-256 `033a43b0…6f231a`) |
| KokoroSwift (`mlalma/kokoro-ios`) | `1.0.11`, commit `4d6d1d8f…682354` | MIT | Git tag + packaging patch `Vendor/Patches/kokoro-ios-1.0.11-resource-bundle.patch` |
| MisakiSwift (`mlalma/MisakiSwift`) | `1.0.6`, commit `6835a1ce…6f37e15` | Apache-2.0 (lexicons from misaki, Apache-2.0) | Git tag + packaging patch `Vendor/Patches/MisakiSwift-1.0.6-resource-bundle.patch` |
| MLX Swift (`ml-explore/mlx-swift`) | `0.30.2` (exact, via KokoroSwift) | MIT | SwiftPM |
| MLXUtilsLibrary | `0.0.6` (exact) | Apache-2.0 | SwiftPM |
| swift-numerics | `1.1.1` | Apache-2.0 | SwiftPM (transitive) |
| ZIPFoundation | `0.9.20` | MIT | SwiftPM (transitive) |
| DM Sans | googlefonts/dm-fonts @ `4412393b` | SIL Open Font License 1.1 (`App/Resources/Fonts/OFL.txt`) | Bundled TTFs |

### Why the KokoroSwift/MisakiSwift packaging patch exists

Both packages copy a directory literally named `Resources` into their SwiftPM resource bundle.
On current Xcode, `codesign` rejects an iOS bundle with a top-level `Resources` directory
("bundle format unrecognized, invalid, or unsuitable"), so the app cannot be signed. The patch only
renames that directory (`MisakiSwiftData`, `KokoroSwiftData`), updates the matching
`subdirectory:` lookups, and points kokoro-ios at the local MisakiSwift checkout. No code or
model behaviour changes. Reproduce with `codesign --force --sign - <bundle>` on the unpatched
bundle.

## Models

| Model | Source (pinned revision) | License | Notes |
|---|---|---|---|
| NVIDIA Nemotron 3 Nano 4B, Q4_K_M GGUF | `nvidia/NVIDIA-Nemotron-3-Nano-4B-GGUF` @ `1260a778…611a2c` | NVIDIA Nemotron Open Model License | Commercial use permitted, royalty-free. Redistribution must include a copy of the license and the notice "Licensed by NVIDIA Corporation under the NVIDIA Nemotron Model License". The app downloads the model from NVIDIA's repository (it does not redistribute it), and shows the notice in About → Licenses. Patent/copyright litigation over the model terminates the license. |
| Whisper base.en (ggml) | `ggerganov/whisper.cpp` @ `5359861c…58b1` | MIT (OpenAI Whisper weights, MIT) | |
| Silero VAD v6.2.0 (ggml) | `ggml-org/whisper-vad` @ `9ffd54a1…639b` | MIT | |
| Kokoro 82M v1.0 (MLX safetensors) + `af_heart` voice | `mlx-community/Kokoro-82M-bf16` @ `a71e4d38…c3c` | Apache-2.0 | Byte-identical to the weights used by the KokoroSwift test app |

Models are downloaded by the app after install (not bundled) and verified by SHA-256; see
`Docs/MODEL_MANIFEST.md`.

## License review checklist (release)

- [ ] Include MIT/Apache/OFL notices in the app's About → Licenses screen (implemented in Settings).
- [ ] Re-read the NVIDIA Nemotron Open Model License for the intended distribution; keep the
      attribution notice "Licensed by NVIDIA Corporation under the NVIDIA Nemotron Model License"
      in About → Licenses (and in a NOTICE file if the model is ever re-hosted).
- [ ] Confirm no GPL/LGPL components are linked (none as of this pin set).
