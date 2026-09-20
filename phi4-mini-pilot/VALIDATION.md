# Phi-4 Mini preparation validation

September 19, 2026: all 46 offline harness checks passed. Dataset validation confirms 150 unique cases, 50 per tier, and all ten tools covered. Shell syntax checks passed for the startup, workflow, and Mac orchestration scripts.

Dataset and system prompt were verified byte-for-byte against completed Nemotron run `20260919T220204.845942Z`. The output schema and grading function also match that run. Only model identity, endpoint/container configuration, workflow version, and the removal of the Nemotron-specific template flag differ in the runner.

The suite covers scoring, recovery identity rejection, startup failures, checksum rejection, source-only deployment, reports, and setup without inference. Tests use fabricated outputs and fake Docker/Brev commands; they are not Phi model results.

The public Hugging Face metadata supplied revision `7ff82c2aaa4dde30121698a973765f39be5288c0` and SHA-256 `01999f17c39cc3074afae5e9c539bc82d45f2dd7faa3917c66cbef76fce8c0c2` for `microsoft_Phi-4-mini-instruct-Q4_K_M.gguf` (2,491,874,688 bytes). Startup verifies downloaded bytes against that hash.

No Phi weights were downloaded locally, no Brev changes were made, and no Phi inference was run during preparation. Actual Phi loading, its chat template, JSON generation, and tokenized context fit remain to be verified on Brev. The existing pinned runtime is reused as a candidate, not claimed to be verified with Phi yet.
