# cleanup-eval — the prompt measurement harness

`TranscriptPrompt` is knife-edge tuned: during the hardening pass, seemingly
unrelated edits (adding an example, rewording a rule) repeatedly flipped the
"what is the capital of france" case from *punctuated* to *answered*. **Any
edit to `Sources/AraCore/Formatting/TranscriptPrompt.swift` is unmeasured
until this harness has been re-run**, and the source doc comments and
docs/KNOWN-ISSUES.md point here for exactly that reason.

## Setup (once)

```sh
python3 -m venv .venv
.venv/bin/pip install mlx-lm
```

The model is the one the daemon ships, `mlx-community/Qwen2.5-1.5B-Instruct-4bit`
(~0.9 GB); `mlx_lm.load` fetches it into the Hugging Face cache on first run —
already present if you have run `parrot models download-formatter`.

## Run

```sh
./dump-prompts.sh            # compiles the real sources, writes prompts/*.txt
.venv/bin/python eval.py     # light medium high (default-mode matrix)
.venv/bin/python eval.py light_email light_chat high_email high_chat
```

`dump-prompts.sh` compiles fresh copies of the actual Swift sources with a
tiny driver, so `prompts/` is byte-exact what the daemon sends — never a
reconstruction. Run it again after every source edit. `eval.py` runs every
condition you name (any `prompt_<name>.txt`) through 6 injection and 8
quality cases with explicit per-case checkers, prints a PASS/FAIL table, and
writes `results.json`.

## Reading the result

`results_final.json` is the accepted baseline (the state described in
docs/KNOWN-ISSUES.md): the pre-branch prompt (`before`), the three default-
mode intensities, and the sampled mode compositions (`light_email`,
`light_chat`, `high_email`, `high_chat`). Compare your `results.json`
against it:

- **Regression = any case that passes in the baseline and fails in your
  run**, at any intensity — most importantly the six `inj-*` rows and
  `inj-capital` in particular (the knife-edge case). Latency medians moving
  by tens of ms is noise; a case flipping is not, at temperature 0.
- `inj-hacked` failing is the known state, not a regression — that family
  resists every prompt tried and is caught by `OutputGuard` in the shipped
  chain (test-pinned in `OutputGuardTests`).
- `q-new-paragraph` failing everywhere and `q-enum-*` failing at medium are
  the known state too; see the KNOWN-ISSUES entries.

If your edit changes the accepted state *deliberately*, update
`results_final.json`, the KNOWN-ISSUES tables, and the doc comments in
`TranscriptPrompt.swift` in the same commit.
