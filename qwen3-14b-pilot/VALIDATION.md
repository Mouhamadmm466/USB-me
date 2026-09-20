# Qwen3 14B validation

September 19, 2026: all 46 offline harness checks passed. Dataset validation confirms 150 unique cases, 50 per difficulty, and all ten tools covered. Shell syntax checks passed for startup, workflow, and Mac orchestration.

Dataset and system prompt were verified byte-for-byte against both completed baselines. Their SHA-256 values are `6fb665b082c377a3bfa6765b14bc09d201214dbf701392a2b1443636f3f054ff` and `b7719e9bc7bffcb899349e6159bd87d92b7b3a396327d292ebab01ff2cb9173a`, respectively. The grader, case loading, evaluation, reporting, summary, and review functions are unchanged from Phi; the report viewer is byte-for-byte identical. All 150 request payloads match the Nemotron baseline exactly after excluding the model alias, including the output schema and non-thinking template argument. The pinned runtime digest also matches.

The runner changes model identity, endpoint/container, workflow version, and adds `chat_template_kwargs: {"enable_thinking": false}` as used in the Nemotron baseline. The official Qwen repository metadata verified revision `530227a7d994db8eca5ab5ced2fb692b614357fd`, SHA-256 `500a8806e85ee9c83f3ae08420295592451379b4f8cf2d0f41c15dffeb6b81f0`, and 9,001,752,960 bytes.

The offline checks use fabricated responses and fake Docker commands; they are not model results. Actual Brev results follow.

## Completed Brev evaluation

Run `20260920T023611.195662Z` completed all 150 requests on the NVIDIA L4 using llama.cpp `b11046-60081bb2b` and the original pinned image. The 9,001,752,960-byte model passed SHA-256 verification. The loaded model occupied approximately 9.2 GB of GPU memory.

Before inference, all 150 prompts were rendered and tokenized using the actual server. Every prompt used the closed, empty thinking prefix. The maximum prompt was 1,817 tokens, within the 4,096-token context with room for the 512-token output allowance. This check made no inference requests; its record is `runtime-validation.json`.

The evaluation made exactly 150 scored requests, with no retries, request errors, harness errors, output truncation, or nonempty reasoning content. All responses ended with `finish_reason: stop`; the largest completion was 178 tokens. Total measured request time was 594.347 seconds (9.9 minutes); run wall time, including model verification and report writing, was 10.6 minutes.

Automatic passes: easy 40/50, medium 22/50, hard 21/50; total 83/150 (55.3%). All 150 human reviews remain pending. The final local audit regraded every raw response, checked all totals and model provenance, and confirmed dataset/prompt/schema equality with both baselines.

The HTML report was opened in a browser, its summary and layout inspected, and an actual-response disclosure expanded successfully. The report contains all 150 case sections. Reports, raw responses, requests, and snapshots are saved locally and on Brev.
