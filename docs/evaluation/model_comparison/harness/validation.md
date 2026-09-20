# Validation — workflow 3.0 / 150 scenarios

**No model tests were run for this update.** The 150-case dataset is prepared for the user to start. No inference requests, model-server startup, or container replacement were performed during preparation.

## Offline checks

`python3 -m unittest discover -s checks -v`: **44 tests passed**. These checks use local data and fabricated responses/commands in temporary directories; they are not Nemotron evaluation results.

Verified:

- Exactly 150 cases: 50 easy, 50 medium, 50 hard; unique IDs, titles, coverage keys, and user requests.
- Every one of the ten supported tools has positive proposal cases in every difficulty tier.
- All answer keys follow the defined tool argument and confirmation contracts. Timestamp fields have explicit timezone offsets, and event/query ends are later than starts.
- Case authoring source regenerates the shipped dataset exactly.
- Per-case clocks and transcript status are included in model input; expected outputs, difficulty labels, coverage keys, tags, and review criteria remain outside it.
- Independent datetime checks for midnight/year/leap-day rollovers and both DST occurrences, including elapsed duration across the autumn clock change.
- Maximum combined model-message size remains under 10,000 characters. This is a character-size regression check, not a measured tokenizer count or actual 4K-context compatibility test.
- Mocked 150-request runs retain timeout failures and all planned denominators; no hidden retries. API-contract failures produce incomplete reports.
- Human-reviewed success requires automatic and human checks. Assistant review never counts as human review.
- Reports preserve 50-per-tier denominators for new runs and 3-per-tier denominators for legacy nine-case reports.
- Test catalog contains 150 expandable case cards. User/model text is HTML-escaped; no external scripts/resources are used.
- Deploy-only orchestration uploads and validates without running setup, Docker, or inference and without starting a VM.
- Existing startup/recovery, network binding, model identity, and concurrency lock checks still pass using fake executables.

`python3 pilot.py validate`, case-catalog generation, coverage-manifest generation, and shell syntax checks passed. Existing local model-run folders remain unchanged; the new suite has no results yet.

## Coverage and review limits

The original nine development scenarios are retained, with 141 additional explicitly authored scenarios. This is exposed development material, not a held-out comparison set. `COVERAGE.md` documents primary categories, positive tool proposals, difficulty rationales, and all 150 scenario titles.

The labels were authored and structurally/consistency checked during this update, not independently adjudicated by a human. Automatic JSON checks cannot establish the correctness of factual answers, speech, or clarification wording. Every case includes specific human review criteria.

Speech-recognition errors, partial transcripts, background speech, permission transitions, and tool outcomes are simulated as text/state. Real audio recognition, live multi-turn conversations, native executor enforcement, device performance, actual communications, and app integration are not evaluated.

## Preserved configuration and history

The Brev environment, pinned model and runtime, and existing container are preserved. The legacy `nine-case-pilot` container label remains an ownership marker; dataset validation requires 150 cases for new runs.

Previous actual nine-case runs are retained under `runs/` with their original snapshots. They are not scores for the 150-case dataset. The previous local package and validation/results documents are archived in `backups/before-150-tests/` in the project folder.

Start the evaluation yourself using `bash workflow.sh run` from `/home/ubuntu/nemotron-pilot` on Brev, or `bash run-on-brev.sh run` from the local package folder on your Mac.
