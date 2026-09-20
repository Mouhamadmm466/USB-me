# Qwen3 14B: the same 150-case evaluation

This workflow uses the existing Brev instance `usb-me-nemotron` and is independent of the Nemotron and Phi workflows. Reports use the same HTML and Markdown viewers, structured grading, and optional human review.

## Read the results on your Mac

```bash
cd "/Users/jerem15h/Documents/ChatGPT/USB-Me 2/qwen3-14b-pilot"
bash run-on-brev.sh report
```

This opens the latest completed local HTML report, including all model responses, expected decisions, errors, timings, and human review criteria. It makes no inference requests and does not require the VM to be running.

```bash
# Print the score summary.
cat RESULTS.md

# Open the original 150 test cases.
bash run-on-brev.sh cases

# Download updated results from the running VM.
bash run-on-brev.sh fetch

# Record your assessment of speech and answer keys on the VM, then fetch it.
bash run-on-brev.sh review
```

Automatic results remain provisional until human review. Fetch copies the remote review state over the local copy; use the remote review command above to keep one authoritative review record.

## Repeat the evaluation

Ensure the existing instance is running and no other evaluation is active. Stop the idle Nemotron/Phi model servers to keep the GPU dedicated to Qwen:

```bash
ssh usb-me-nemotron 'docker stop usb-me-pilot-server usb-me-phi4-mini-server'
cd "/Users/jerem15h/Documents/ChatGPT/USB-Me 2/qwen3-14b-pilot"
bash run-on-brev.sh run
```

Run starts/reuses the existing VM, uploads this source, verifies or downloads the pinned model, and makes 150 scored requests with no inference retries. Each run saves its dataset, system prompt, schema, runner, request payloads, raw responses, timing, runtime identity, and reports. Earlier runs are retained.

For separate deployment and setup:

```bash
# On your Mac: upload and validate source only.
bash run-on-brev.sh deploy

# On Brev: download/verify weights and start the model without inference.
cd /home/ubuntu/qwen3-14b-pilot
bash workflow.sh setup

# On Brev: run the evaluation and generate reports.
bash workflow.sh run
```

All workflows share the same run/deploy lock. The Qwen server is `usb-me-qwen3-14b-server`, alias `usb-me-qwen3-14b-q4km`, with a loopback-only endpoint at `127.0.0.1:8082`.

## Comparison controls

The dataset and system prompt are byte-for-byte identical to the completed Nemotron and Phi baselines. The output schema, grader, report viewer, temperature 0, seed 42, 512 output-token cap, 4096 context, one slot, 120-second timeout, and pinned llama.cpp image are retained. Qwen uses its own GGUF chat template with `enable_thinking: false`, the same request-level switch used for Nemotron. Reasoning is also disabled in the server and request.

This is a comparison under the existing USB-Me settings. Qwen's model card recommends different sampling for its general use; this run does not tune Qwen independently. Tokenizer context errors remain visible as incomplete-run diagnostics. No real phone, message, calendar, or file actions execute.

## Model provenance

Official repository: https://huggingface.co/Qwen/Qwen3-14B-GGUF

Revision: `530227a7d994db8eca5ab5ced2fb692b614357fd`

Filename: `Qwen3-14B-Q4_K_M.gguf`

SHA-256: `500a8806e85ee9c83f3ae08420295592451379b4f8cf2d0f41c15dffeb6b81f0`

Bytes: 9,001,752,960. Weights are downloaded on Brev; they are not copied to your Mac.

## Offline verification

```bash
python3 pilot.py validate
python3 -m unittest discover -s checks -v
```

These checks use fabricated responses and fake Docker commands. Actual model validation and run details are recorded in `VALIDATION.md`.

To stop compute after using the VM, run `brev stop usb-me-nemotron` on your Mac. Stopping the instance preserves its files.
