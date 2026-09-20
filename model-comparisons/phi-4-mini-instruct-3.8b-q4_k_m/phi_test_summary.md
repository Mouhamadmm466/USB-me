# Phi-4 Mini Instruct 3.8B Q4_K_M comparison

Completed 150-test run: `20260919T233318.261723Z` (September 19, 2026).

[View tests and results](20260919T233318.261723Z/report.html) · [Markdown report](20260919T233318.261723Z/report.md)

| Difficulty | Tests completed | Automated passes |
|---|---:|---:|
| Easy | 50 | 28 |
| Medium | 50 | 12 |
| Hard | 50 | 11 |
| Total | 150 | 51 |

Human review is pending; automated scores are provisional. The Nemotron baseline passed 56/150 automatic checks. This is a single run per model and does not establish a statistically reliable ranking.

The run preserves the exact dataset, system prompt, output schema, runner snapshot, requests, raw responses, runtime identity, and reports. Dataset and prompt hashes match the Nemotron baseline. Both models used Q4_K_M, 4096 context, temperature 0, seed 42, 512 output tokens, and the same pinned llama.cpp runtime. Phi uses its own chat template, without the Nemotron-specific enable_thinking argument.

This is a verified copy of the completed run; no new inference was performed. The original remains in `phi4-mini-pilot/runs/20260919T233318.261723Z`. Reusable workflow source is in `phi4-mini-pilot/` at the repository root.

Model: community GGUF `bartowski/microsoft_Phi-4-mini-instruct-GGUF`, revision `7ff82c2aaa4dde30121698a973765f39be5288c0`. Verified model SHA-256: `01999f17c39cc3074afae5e9c539bc82d45f2dd7faa3917c66cbef76fce8c0c2`.
