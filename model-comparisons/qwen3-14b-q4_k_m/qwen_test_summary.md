# Qwen3 14B Q4_K_M comparison

Completed 150-test run: `20260920T023611.195662Z` (September 19, 2026 in New York; September 20 UTC).

[View tests and results](20260920T023611.195662Z/report.html) · [Markdown report](20260920T023611.195662Z/report.md)

| Difficulty | Tests completed | Automated passes |
|---|---:|---:|
| Easy | 50 | 40 |
| Medium | 50 | 22 |
| Hard | 50 | 21 |
| Total | 150 | 83 |

Human review is pending; automated scores are provisional. Nemotron passed 56/150 and Phi passed 51/150 under the same grading. These are single runs on exposed development cases, not a statistically established general model ranking.

The run preserves the dataset, prompt, schema, runner, requests, raw responses, runtime identity, and reports. Dataset and prompt hashes and the output schema match both baselines. The runtime image, Q4_K_M quantization, context 4096, temperature 0, seed 42, 512 output tokens, one slot, 120-second request timeout, and zero retries are unchanged. Qwen uses its own chat template with thinking disabled; all request payloads match Nemotron except the model alias.

All 150 requests completed normally. Total request time was 594.347 seconds; complete-run wall time was 10.6 minutes. No extra inference smoke tests were performed. Prompt/template validation made no inference requests.

This is a verified copy of `qwen3-14b-pilot/runs/20260920T023611.195662Z`. `SHA256SUMS.json` records this archive's file hashes. Review changes made later through the live workflow do not automatically update this archive.

Model: official GGUF [Qwen/Qwen3-14B-GGUF](https://huggingface.co/Qwen/Qwen3-14B-GGUF), revision `530227a7d994db8eca5ab5ced2fb692b614357fd`. Verified model SHA-256: `500a8806e85ee9c83f3ae08420295592451379b4f8cf2d0f41c15dffeb6b81f0`.

To open the latest local report:

```bash
cd "/Users/jerem15h/Documents/ChatGPT/USB-Me 2/qwen3-14b-pilot"
bash run-on-brev.sh report
```

To print its summary: `cat RESULTS.md`. To fetch updated reports from the running VM: `bash run-on-brev.sh fetch`. To record your speech and answer-key review on Brev: `bash run-on-brev.sh review`.
