# Third-party acknowledgements

## Inference core (user's Mac, downloaded on first server boot)

| Artifact | Source | License |
| --- | --- | --- |
| Whisper large-v3-turbo weights (`ggml-large-v3-turbo.bin`, whisper.cpp format) | https://huggingface.co/ggerganov/whisper.cpp | OpenAI Whisper weights: MIT (code + weights per OpenAI Whisper repo) |
| Qwen3-4B-Instruct-2507 (`Q4_K_M` GGUF) | https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF (quant of Apache-2.0 weights; Qwen's own GGUF repo is access-gated, so the public unsloth mirror is used) | Apache 2.0 |
| whisper.cpp binaries (`whisper-cli`, etc.) | `brew install whisper-cpp` | MIT |
| llama.cpp binaries (`llama-server`) | `brew install llama.cpp` | MIT |

Effect/TypeScript runtime deps (`effect`, `@effect/platform`,
`@effect/platform-bun`) are MIT. Pinned versions live in
`server/bun.lock` when generated (`bun install`).

Weight files are versioned + SHA-256-pinned on first download
(`server/data/models/manifest.local.json`, trust-on-first-use, verified on
every boot, removable by deleting `server/data/models/`).

## System speech backends (offline fallback, no bundled weights)

| Backend | Source | License / terms |
| --- | --- | --- |
| Apple `SpeechTranscriber` / `SpeechAnalyzer` / `DictationTranscriber` | macOS/iOS SDK, system-managed assets | Apple platform API |
| `SFSpeechRecognizer` (on-device enforced) | macOS/iOS SDK | Apple platform API |

## Deferred comparison backends (NOT shipped — license review required first)

| Candidate | Code | Weights |
| --- | --- | --- |
| FluidAudio Parakeet EOU 120M / TDT 0.6B | Apache 2.0 | Inspect each model card; TDT v3 weights CC BY 4.0 (attribution) |
| WhisperKit / whisper.cpp | MIT | MIT (Whisper weights) |
| SenseVoiceSmall | MIT source | FunASR model agreement — needs specific review |
| Moonshine | Mostly MIT, documented legacy exceptions | Per-checkpoint review |
| Qwen3-0.6B (cleanup experiment) | Apache 2.0 (MLX Swift LM) | Apache 2.0 |

Any shipped model pack must record name, version, source URL, license,
conversion commit, and file hash in its manifest (`ModelManifestEntry`) and
here. Model downloads are data consumed by shipped runtimes — never
executable code.
