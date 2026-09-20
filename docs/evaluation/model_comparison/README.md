# Choosing the model

Before building the app, we had to pick the brain. We tested three open models on the same 150
tests, with the same settings, and kept every file so anyone can check the work.

## The result

<table>
<tr><th>Model</th><th>Size</th><th>Easy (50)</th><th>Medium (50)</th><th>Hard (50)</th><th>Total</th></tr>
<tr><td>Qwen3 14B</td><td>14 billion</td><td>40</td><td>22</td><td>21</td><td><b>83 / 150</b></td></tr>
<tr><td>Nemotron 3 Nano 4B</td><td>4 billion</td><td>29</td><td>14</td><td>13</td><td><b>56 / 150</b></td></tr>
<tr><td>Phi 4 Mini Instruct</td><td>3.8 billion</td><td>28</td><td>12</td><td>11</td><td><b>51 / 150</b></td></tr>
</table>

## What we chose, and why

We chose **Nemotron 3 Nano 4B**, even though Qwen3 14B scored higher.

The reason is simple. Qwen3 14B is about three and a half times bigger. A 14B model does not fit in
an iPhone's memory budget next to a speech recognition model and a voice model. It would also be
slow and would drain the battery. The app has to run everything on the phone, so a model that cannot
fit is not a real option, no matter how well it scores.

So the real question was: **among the models small enough for a phone, which is best?** Nemotron 4B
beat Phi 4 Mini 3.8B at almost the same size. That is the comparison that mattered, and Nemotron
won it.

The Qwen3 14B run is still useful. It shows us the gap between what fits on a phone today and what a
bigger model can do. That gap is the thing that gets smaller every year.

## How the tests were run

The point of this setup was that the three runs are truly comparable. Nothing changed between them
except the model itself.

Every run used:

* the same 150 test cases
* the same system prompt
* the same output schema
* Q4_K_M quantization
* a context window of 4096 tokens
* temperature 0 and seed 42, so the answers are repeatable
* a limit of 512 output tokens
* the same pinned llama.cpp runtime
* one request at a time, 120 second timeout, no retries

Each model used its own chat template, because that is how each model is meant to be used.

Every run folder keeps the dataset, the prompt, the schema, the runner code, the raw responses, and
a readable report. The Qwen run also stores a file of SHA 256 hashes so you can prove the archive was
not edited afterwards.

## Being honest about these numbers

Three things are worth saying plainly.

**1. The scores are automatic checks, not human judgement.** A test counts as a pass only if the
answer matched what the checker expected. Some answers that a person would call correct are marked
as failures. Human review has not been done yet.

**2. This is one run per model.** One run is not enough to say one model is truly better than
another. It is enough to see a clear difference in size, and 83 against 56 against 51 is a clear
difference. It is not enough to argue about small gaps.

**3. The test cases were visible during development.** They are not a hidden test set. That is fine
for choosing between models under the same conditions, but it is not a claim about how these models
perform in general.

The app itself is tested separately and much more heavily. See
[the evaluation overview](../README.md) for that.

## The files

* `nemotron_4b/` the model we chose. Open `report.html` in a browser to read every test and answer
* `phi4_mini_3_8b/` the other small model
* `qwen3_14b/` the large model, for reference
* `harness/` the test cases and the Python runner used for all three

Each model folder has a `summary.md` with its own detail, including the exact model file and its
SHA 256 hash, so you can download the same file and check it matches.
