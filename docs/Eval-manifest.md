# Evaluation fixtures — provenance manifest

## Text corpus (human transcripts, typed)

- `Tests/OmilCoreTests/Fixtures/corpus.json` — version `omil-corpus-1`, 25 cases.
- Splits: `dev` (14) for rule development, `heldout` (11) for evaluation.
- Each case: raw transcript, intended output, acceptable alternatives,
  protected spans, locale, tags, `mustEdit` flag.
- Reproducible command: `swift run omil-eval --corpus <path> [--split dev|heldout]`

## Audio fixtures (SYNTHETIC — not human evaluation)

- `Tests/OmilCoreTests/Fixtures/audio-synth/*.aiff`
- Provenance: macOS `say -v Samantha`, default AIFF output, generated
  2026-09-19 on the reference Mac. Utterances read from the corpus
  (`make-it-42`, `make-it-42-sorry-21`, `do-not-send`, `alice-bob`).
- Purpose: bootstrap ASR→cleanup plumbing and measure repair-cue retention
  through REAL on-device inference (`AppleSpeechBackend.transcribeFile`).
- Explicitly NOT representative of human speech (single TTS voice, clean
  channel, read style, no disfluencies, no accents, no noise).
- Command: `swift run omil-eval --asr-eval`
- Recorded 2026-09-19: 4/4 exact, cue retention 2/2.

## Required before any quality claim

Consented human recordings with: human transcript, intended cleaned output,
protected content, acceptable alternatives/abstention, speaker/acoustic
metadata. Separate dev/held-out speakers. See `docs/product-plan.md`
evaluation plan. Synthetic results must never be presented as human eval.
