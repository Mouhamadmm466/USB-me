# Phi-4 Mini: the same 150-case evaluation

Use the existing Brev instance `usb-me-nemotron`. This directory is independent of `nemotron-pilot`.

## Guided first setup

On your Mac:

```bash
cd "/Users/jerem15h/Documents/ChatGPT/USB-Me 2/phi4-mini-pilot"
bash run-on-brev.sh deploy
```

Deployment uploads and validates source only. It does not download weights, stop containers, or run inference. The instance must already be running.

On Brev, when the Nemotron test is idle:

```bash
docker stop usb-me-pilot-server
cd /home/ubuntu/phi4-mini-pilot
bash workflow.sh setup
```

Setup downloads about 2.49 GB, verifies SHA-256, starts Phi, and records its verified identity. It sends no chat-completion requests. Successful setup ends with `Model server ready. Setup record recovered.` If it fails, inspect the printed diagnostics before testing.

## Run and review

On Brev, after setup succeeds:

```bash
bash workflow.sh run
bash workflow.sh review
```

Run makes 150 scored requests without automatic inference retries. Review is optional, resumable, and sends no inference. JSON passes remain provisional until human speech review.

On your Mac, fetch and open results:

```bash
cd "/Users/jerem15h/Documents/ChatGPT/USB-Me 2/phi4-mini-pilot"
bash run-on-brev.sh fetch
bash run-on-brev.sh report
```

Later, `bash run-on-brev.sh run` on your Mac starts/reuses Brev, deploys this source, runs the evaluation, and downloads results. Stop an idle Nemotron container first for consistent GPU availability. Mac source is authoritative; deploy replaces the corresponding remote source files. Existing run directories are retained. Each run snapshots dataset, prompt, schema, runner, requests, responses, timing, and runtime identity.

## Comparison controls

Cases and system prompt are byte-for-byte identical to Nemotron's completed baseline `20260919T220204.845942Z`. Schema and grading are unchanged. Temperature 0, seed 42, output cap 512, context 4096, one slot, reasoning off, and the pinned llama.cpp image are retained. Phi uses its GGUF chat template; the Nemotron-specific `enable_thinking` template argument is omitted. Phi's different tokenizer may cause context-limit errors; the runner preserves these as an incomplete evaluation rather than silently truncating or changing settings.

This measures adherence to the existing USB-Me JSON decision contract. It does not benchmark Phi's separate native function-calling format. No real phone, message, calendar, or file actions execute.

Phi runtime: container `usb-me-phi4-mini-server`, alias `usb-me-phi4-mini-q4km`, loopback endpoint `127.0.0.1:8081`. The model directory is `/home/ubuntu/phi4-mini-pilot/models`. Both workflow copies retain the shared run/deploy lock to prevent overlapping workflow operations.

## Model provenance

Repository: https://huggingface.co/bartowski/microsoft_Phi-4-mini-instruct-GGUF
Base model: https://huggingface.co/microsoft/Phi-4-mini-instruct
This is a community GGUF quantization of Microsoft's model.

Revision: `7ff82c2aaa4dde30121698a973765f39be5288c0`

Filename: `microsoft_Phi-4-mini-instruct-Q4_K_M.gguf`

SHA-256: `01999f17c39cc3074afae5e9c539bc82d45f2dd7faa3917c66cbef76fce8c0c2`

Bytes: 2491874688

## Switch back to Nemotron

On Brev:

```bash
docker stop usb-me-phi4-mini-server
docker start usb-me-pilot-server
```

To stop compute when finished, run `brev stop usb-me-nemotron` on your Mac. Stopping the VM preserves its files.

## Offline validation

```bash
python3 pilot.py validate
python3 -m unittest discover -s checks -v
```

These checks use fabricated outputs and fake Docker commands. They cannot establish actual Phi runtime compatibility or model quality; first setup and inference must be verified on Brev.
