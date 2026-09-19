# USB-Me: 150-test local voice-assistant workflow

Workflow **3.0** conducts **150 independent model-decision tests: 50 easy, 50 medium, and 50 hard** on the existing Brev environment `usb-me-nemotron`, using the same pinned Nemotron 3 Nano 4B Q4_K_M model. **The expanded dataset has been prepared and validated without running it against the model.**

## Start the tests yourself

If already connected to Brev:

```bash
cd /home/ubuntu/nemotron-pilot
bash workflow.sh run
```

That command verifies the existing model server, recovers its runtime record, then sends one request per case. Progress is displayed as `[1/150]` through `[150/150]`. A complete normal run makes 150 requests with no automatic inference retries. A model answer failure does not stop the other tests; a broken server/API contract stops with an incomplete report.

From your **Mac**, you can instead double-click **Run Tests.command** in the project folder, or run:

```bash
cd "/Users/jerem15h/Documents/ChatGPT/USB-Me 2/nemotron-pilot"
bash run-on-brev.sh run
```

The Mac command starts/resumes the existing Brev environment if needed, uploads the current source and dataset, runs all 150, and copies results back. It creates no new instance. Mac source is authoritative for uploads; edits made only on Brev will be replaced by a later Mac run/deployment.

To connect from your Mac:

```bash
brev refresh
brev shell usb-me-nemotron
```

If the environment is stopped, first run `brev start usb-me-nemotron` on the Mac. After connecting, run the two Brev commands above. `exit` disconnects without stopping the environment.

## Inspect before running

On Brev:

```bash
cd /home/ubuntu/nemotron-pilot
bash workflow.sh validate   # Checks 50/50/50, uniqueness, tool contracts; no model calls
less COVERAGE.md            # Categories, tool coverage, all scenario titles and rationales
less TESTS.md               # Every prompt, input state, answer key, and review criterion
```

Press `q` to leave `less`. On your Mac, double-click **View Tests.command** to open the expandable `tests.html` catalog. `bash workflow.sh cases` regenerates the catalog without starting the model.

## Read results after running

Inside Brev:

```bash
less RESULTS.md
less "runs/$(cat runs/LATEST)/report.md"
bash workflow.sh review
```

`RESULTS.md` is now automatically updated after each completed run and while reviewing the latest run. It identifies the dataset version, run ID, and total case count. `runs/LATEST` points to the most recent completed run; an incomplete run saves its own report without replacing that pointer. The old nine-case runs remain available and are explicitly labeled as nine-case results. Until the first 150-case run completes, there are no 150-case scores.

Human review shows the case context, expected fields, model output, and speech criteria. Enter `y` or `n`; use `q` to pause. Run review again to resume. Review sends no inference requests. Automatic passes are provisional: an answer with correct JSON that never asks for confirmation can still fail the speech review.

Each run is saved in `runs/<timestamp>/` with:

- `report.html`: expandable report containing inputs, outputs, failures, and review records.
- `report.md` and `results.json`: readable and machine-readable results, requests, raw responses, errors, and timings.
- `dataset.json`, `system_prompt.txt`, `output_schema.json`, `pilot.py`: exact evaluation snapshots.
- Recorded model checksum, runtime digest, GPU details, decoding settings, and per-tier denominators of 50.

To fetch a run made directly on Brev and open its report, on your Mac:

```bash
cd "/Users/jerem15h/Documents/ChatGPT/USB-Me 2/nemotron-pilot"
bash run-on-brev.sh fetch
bash run-on-brev.sh report
```

## What the 150 scenarios cover

The dataset exercises **all ten supported tools in every difficulty tier**: contact lookup, calls, messages, calendar reading/creation/update, reminders, scoped file search/opening, and allowed app launches. It also covers everyday arithmetic, conversions, summaries, factual answers, cancellation, interruption, permission denial, unsupported requests, offline limitations, failed/uncertain execution, and prompt injection.

- **Easy:** one clear goal with complete information. Required confirmation alone does not make a case harder.
- **Medium:** one material missing detail, ambiguity, reference, correction, access issue, or sequencing constraint.
- **Hard:** interacting constraints such as stale approval plus edits; relative dates plus daylight saving; scope plus recency plus revoked access; or recovery plus duplicate-action risk.

Each case has a unique ID, request, title, coverage key, supplied state, expected structured fields, and specific speech-review criteria. The original nine cases are retained; **141 additional scenarios** expand coverage. They are explicitly authored, not a name-replacement generator. See `COVERAGE.md` for the complete index and category counts.

This is an exposed **development evaluation**, not a held-out benchmark or production-safety certification. Real messages, calls, calendar writes, and file operations never execute. Speech is represented by transcripts and state: ASR accuracy, live multi-turn behavior, actual iPhone execution, battery, heat, and audio latency require separate testing.

The tool contracts are defined in `system_prompt.txt`. Timers/alarms, media control, navigation, email, file writes, banking, deletion, arbitrary code/URLs, and recurring-series writes are not implemented. Tests in those areas measure honest limitation handling rather than pretend those capabilities exist.

## Configuration and maintenance

The model/server configuration remains unchanged: NVIDIA Nemotron3 Nano 4B Q4_K_M, 4,096-token context, one slot, reasoning disabled, temperature 0, seed 42, 512 output tokens, 120-second request timeout, no hidden retries. The server is local to the Brev VM at `127.0.0.1:8080`. No OpenAI API is used for inference.

- Model revision: `1260a7780236524372acab3fdff3da563b611a2c`.
- Model SHA-256: `be5d9a656a51922f24f1f09a759cebb694e1f5d9728bf0ef9f8c972c5a0b5ef2`.
- Runtime digest: `ghcr.io/ggml-org/llama.cpp@sha256:131a7be5d90d6df75f32ffad405d71e354e9bdba806264b6a905339283925b85`.
- Container name `usb-me-pilot-server` and its legacy `nine-case-pilot` ownership label are retained so the existing server can be reused. The **dataset**, not that label, controls the number of tests.

Use `bash workflow.sh status` to inspect readiness. Always use `workflow.sh run` for evaluation so startup and identity checks precede inference. Do not fabricate `runtime.json` or bypass checksum checks. A lock prevents simultaneous workflow runs or deployment during a run.

`bash run-on-brev.sh deploy` uploads and validates source only. It does not start the model, create an instance, or send inference requests; the existing instance must be reachable.

To edit cases, update `datasets/build_cases.py`, then run:

```bash
python3 datasets/build_cases.py
python3 datasets/coverage.py
python3 pilot.py validate
python3 viewer.py cases
```

These commands are offline. Increment the dataset version after changing cases or labels. Keep prompts and grading frozen when comparing models. The largest current model message is under 10,000 characters; this is a size regression check, not a measured token count. Actual server context-limit errors will be retained as incomplete-run diagnostics.

For offline harness checks (fabricated outputs in temporary directories; no GPU):

```bash
python3 -m unittest discover -s checks -v
```

The prior package is preserved locally under `backups/before-150-tests/`; earlier run folders are untouched. Brev compute charges continue while the instance is running. Use `brev stop usb-me-nemotron` on your Mac when finished to retain the instance while stopping compute.
