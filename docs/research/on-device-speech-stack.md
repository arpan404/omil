# Omil on-device speech stack research

Research date: 2026-09-19

Revised after architecture review. This document records source evidence and proposed experiments; no Omil device benchmarks have run. The [product plan](../product-plan.md) owns scope, milestone order, and acceptance criteria.

## Recommendation

Build Omil as a native Swift app with interchangeable speech engines and a separate cleanup pipeline. Do not bind the product to one recognizer or one device list.

The recommended stack is:

1. Evaluate Apple's `SpeechAnalyzer` and `SpeechTranscriber` as the primary OS 26+ candidate where device, locale, and assets permit it. Apple manages the on-device speech assets, which reduces deployment work. Default selection remains conditional on Omil's recorded correction and lifecycle tests. [Apple's SpeechAnalyzer session](https://developer.apple.com/videos/play/wwdc2025/277/) and [SpeechTranscriber documentation](https://developer.apple.com/documentation/speech/speechtranscriber)
2. Choose one open comparison backend for the first experiment. FluidAudio Parakeet EOU 120M is a candidate for English streaming; TDT 0.6B is a candidate for finalized transcription in its 25 European languages. [FluidAudio](https://github.com/FluidInference/FluidAudio) and [NVIDIA's Parakeet TDT v3 model card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
3. Consider WhisperKit instead when broader language coverage is the comparison priority. Its native Swift/Core ML implementation includes microphone streaming, timestamps, language detection, prompting, and converted Whisper models. The shortlist does not commit Omil to shipping every runtime. [Argmax OSS](https://github.com/argmaxinc/argmax-oss-swift)
4. Represent cleanup as inspectable edits over immutable transcript snapshots. Compare deterministic rules, local-model edits, and a hybrid in the first milestone. Source grounding is useful evidence, but semantic preservation needs additional checks and evaluation.
5. Test global insertion on Mac and app-owned recording coordinated with a keyboard on iPhone and iPad. The keyboard cannot record directly; that restriction does not rule out coordination with the containing app. Wispr documents a keyboard-driven iPhone workflow. Its implementation and Omil's local-inference feasibility remain separate questions. [Apple's custom keyboard guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html), [Wispr's iPhone instructions](https://docs.wisprflow.ai/articles/6409258247-starting-your-first-dictation).

The first milestone must measure correction quality on real recordings, Mac insertion reliability, and the mobile recording-to-keyboard path with local inference. Use these results to decide supported devices, models, and release order. A rule-only cleaner is not yet evidence that the core correction requirement is met.

## Product constraints that shape the design

### iPhone and iPad are not macOS

Apple explicitly says custom keyboard extensions have no microphone access. Third-party keyboards are also unavailable in secure text fields and phone-pad fields, and an app can reject them entirely. These are restrictions on the extension process, not proof that an app-plus-keyboard workflow is impossible. [Custom keyboard limitations](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html) and [current open-access documentation](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard).

Wispr's instructions describe selecting its keyboard, tapping the microphone, speaking, stopping, and receiving text in the current field. This is first-party evidence of the interaction, not documentation of how Wispr implements it. It also does not show that equivalent local processing works within every iOS background state. [Wispr's iPhone workflow](https://docs.wisprflow.ai/articles/6409258247-starting-your-first-dictation).

The proposed Omil experiment puts recording and local inference in the containing app. A lightweight keyboard coordinates session commands and inserts the result. Test public App Group communication, Full Access requirements, session activation, and state restoration. Shared storage does not grant execution time or wake a suspended app. Attach a session ID to every request/result and acknowledge insertion to prevent stale or duplicate delivery. This is an architectural hypothesis pending physical-device tests.

`AudioRecordingIntent` provides another recording entry point and requires an active Live Activity while recording on iOS and iPadOS. Test an intent-started session together with the containing app and keyboard rather than assuming the intent solves inference or delivery lifecycle. [AudioRecordingIntent](https://developer.apple.com/documentation/appintents/audiorecordingintent).

Run the full ASR-and-cleanup path while another app is foregrounded, after idle periods, through interruptions, while locked, and following suspension or termination. Report when explicit reactivation is necessary. Foreground model performance and microphone permission alone do not establish background feasibility.

Keep in-app recording with copy/share and keyboard insertion of completed results as fallbacks. Adopt a reduced mobile workflow only after recording what the full experiment could and could not support.

The macOS product can offer a global hotkey, a floating recording indicator and text insertion after the user grants Accessibility permission. This creates a distribution choice. Mac App Store apps must use App Sandbox, while arbitrary control of other apps and Accessibility-based automation conflict with the sandbox model. A direct, notarized build is the practical route for full global insertion; a Mac App Store build should use clipboard handoff or a narrower integration. [App Sandbox guidance](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox) and [Accessibility trust API](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)

### Entirely local must remain true after installation

Model download is compatible with a local product. The privacy boundary is inference and user data: audio, transcripts, prompts and corrections must not leave the device. Apple supports downloading and compiling Core ML models after installation. Downloaded artifacts should be signed or hash-pinned, versioned, resumable and deletable by the user. [Apple's Core ML model download guidance](https://developer.apple.com/documentation/coreml/downloading-and-compiling-a-model-on-the-user-s-device)

Avoid hidden cloud fallbacks. Airplane-mode operation should be part of release testing, not just a marketing statement.

## Proposed architecture

Keep the audio, recognition, editing and delivery layers independent:

```text
AVAudioEngine / audio file
        |
backend-negotiated audio conversion and bounded buffer
        |
VAD + end-of-utterance detector
        |
Speech engine
  - Apple SpeechTranscriber
  - FluidAudio Parakeet / SenseVoice
  - WhisperKit
  - Moonshine, if a device benchmark justifies it
        |
immutable raw tokens, alternatives and word times
        |
edit proposal experiment
  - deterministic rules
  - local-model proposals
  - hybrid proposals
        |
source/scope validation, abstention and transcript journal
        |
final text + undoable edit history
        |
destination revalidation, insertion receipt and scoped undo
```

Start with one shared Swift package and thin platform adapters. Internal interfaces should cover:

- `TranscriptionBackend` declares audio requirements and capabilities, then emits identified segment revisions with timing and alternatives when available.
- `TranscriptCleaner` accepts an immutable snapshot and proposes edits or abstentions.
- `TextDestination` prepares and revalidates the target, commits once, and reports supported undo semantics.
- Platform adapters manage recording, endpointing, session coordination, interruptions, and delivery permissions.

Store recognizer output in immutable snapshots with session IDs, snapshot revisions, stable token IDs, and separately identified alternatives. Unchanged tokens may retain identity across revisions; revised tokens need new IDs. Every edit names its input snapshot, target and evidence tokens, operation, candidate/dependency IDs, and rule/model version. Persist the accepted journal so output can be replayed even when model inference is nondeterministic. Reject stale proposals or explicitly rebase them. Do not persist `String.Index` as an edit identity across string revisions or launches.

Approved normalization records its source span, locale, rule version, and derived value. Reversal operations refer to candidate or edit IDs, and undo accounts for dependent edits. The product plan specifies the initial conceptual record contract; use the prototype to refine it before splitting more packages.

For Mac insertion, capture the intended destination/selection at recording start and revalidate them after processing. If the target changed or cannot be safely verified, keep the result for explicit insertion. Undo should reverse only Omil's insertion, with a receipt and current-content precondition, rather than restoring a whole field over later typing. Restore a temporary clipboard write only if Omil still owns the contents and the change count matches. Verify paste-consumption behavior per host; do not overwrite a newer user copy.

## Apple-native baseline

### SpeechAnalyzer and SpeechTranscriber

Apple introduced the newer Speech framework path in the OS 26 generation. `SpeechAnalyzer` accepts progressive or complete audio and emits volatile and final results asynchronously. `SpeechTranscriber` is intended for live and long-form speech, runs on-device and supports time-indexed results. Locale assets are managed through `AssetInventory`, shared at the system level and subject to runtime device and locale availability. [WWDC25: Bring advanced speech-to-text to your app](https://developer.apple.com/videos/play/wwdc2025/277/), [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber), and [AssetInventory](https://developer.apple.com/documentation/speech/assetinventory)

This is the initial candidate because it avoids bundling a large model and tracks Apple's hardware-specific optimizations. It must still sit behind `TranscriptionBackend` because:

- `SpeechTranscriber.isAvailable` and supported locales must be checked at runtime.
- Asset installation can be pending or unavailable.
- Output quality will differ by language, device, acoustic condition and domain.
- A user may prefer a downloaded model with more predictable cross-version behavior.

Measure whether each backend preserves repair cues, rejected values, negation, and clause boundaries on real speech. An immutable ASR transcript is only the recognizer's output; it is not proof of verbatim capture. If required evidence is missing from both text and alternatives, cleanup must abstain or use an explicit audio retry path rather than invent it.

Negotiate audio format per backend. Apple's `bestAvailableAudioFormat` reports a compatible format from installed assets, and `SpeechAnalyzer` does not transparently resample input. A shared fixed 16 kHz stage can be incompatible or cause unnecessary conversion. Preserve audio time mappings through format conversion and VAD windows. [Apple's audio format contract](https://developer.apple.com/documentation/speech/speechanalyzer/bestavailableaudioformat%28compatiblewith%3A%29).

Use Apple's `SpeechDetector` where it works for the selected path, or use the same local VAD as the fallback stack. Gating recognition during silence reduces computation and false starts. [SpeechDetector](https://developer.apple.com/documentation/speech/speechdetector)

### Older Apple speech APIs

`SFSpeechRecognizer` is not a safe foundation for an offline promise. An older recognition request is guaranteed to stay on-device only when the recognizer reports `supportsOnDeviceRecognition` and the request sets `requiresOnDeviceRecognition`. Apple also notes that on-device recognition can be less accurate than server recognition. [On-device support](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition) and [on-device request requirement](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition)

On the OS 26 generation, `DictationTranscriber` can cover hardware or languages unsupported by the new speech model by using the same on-device assets as system dictation. Treat this as another runtime-probed fallback rather than a universal guarantee. [DictationTranscriber](https://developer.apple.com/documentation/speech/dictationtranscriber)

## Core ML, MLX and Metal

Core ML is the main deployment route for ANE-backed speech models. `MLComputeUnits.all` allows Core ML to place operations across the CPU, GPU and Neural Engine. `cpuAndNeuralEngine` excludes the GPU, but neither option guarantees that every operator runs on the ANE. Placement is decided by the framework, model graph and device. [MLComputeUnits](https://developer.apple.com/documentation/coreml/mlcomputeunits)

This leads to two practical rules:

- Measure the converted model on physical devices. A claim that a model is "Core ML" does not prove that its slow path stays off the CPU.
- Cache compiled model assets and warm them before the user's first dictation when possible. Cold compilation can take seconds.

MLX Swift is a Metal and unified-memory framework for Apple silicon. It is useful for small cleanup language models and experiments on iPhone, iPad and Mac, but it is not an ANE runtime. [Apple's MLX session](https://developer.apple.com/videos/play/wwdc2025/315/) and [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm)

Use Core ML as the initial custom-ASR runtime and consider MLX for a quantized text-model experiment. These choices still require execution-state validation. Apple's newer background inference entitlement documentation describes Neural Engine access requirements, while its Foundation Models lab describes background availability with possible resource-related failures. Neither establishes that every model/backend works throughout Omil's mobile session lifecycle. Test the intended SDK/OS combination and distinguish released APIs from beta documentation. [Background inference entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.background-tasks.continued-processing.inference), [Apple ML group lab](https://developer.apple.com/videos/play/wwdc2026/8016/).

## Speech model and runtime comparison

| Option | Best use | Streaming | Languages | Apple execution | Package and memory evidence | License notes |
| --- | --- | --- | --- | --- | --- | --- |
| Apple SpeechTranscriber | Primary candidate on supported OS 26 devices | Native progressive and final results | Runtime locale list | Apple-managed on-device stack | No app-bundled model; assets are system-managed | Platform API |
| FluidAudio Parakeet EOU 120M | Low-latency English dictation | True streaming with EOU | English | Swift + Core ML, designed for ANE | 120M parameters; FluidAudio publishes device cold and warm timings | FluidAudio code Apache 2.0; inspect each model card |
| FluidAudio Parakeet TDT 0.6B v3 | High-quality finalized European-language transcription | Batch/utterance oriented | 25 European languages | Swift + Core ML | 600M parameters; upstream card states at least 2 GB RAM, but converted Apple peak RSS must be measured | NVIDIA weights CC BY 4.0 |
| WhisperKit | Broad-language fallback and baseline | Wrapper provides microphone streaming over chunked Whisper inference | Multilingual Whisper coverage | Swift + Core ML | Base English about 147 MB, small English about 487 MB, compressed large-v3 Turbo listed about 626 MB | MIT code and Whisper weights |
| whisper.cpp | Portable baseline, old-device experiments | Wrapper-level streaming | Multilingual Whisper coverage | CPU/Metal plus optional Core ML encoder | Published RAM ranges from about 273 MB for tiny to 3.9 GB for large | MIT |
| FluidAudio SenseVoiceSmall | Compact CJK-focused utterances | Bounded utterances, not a general streaming decoder | Mandarin, Cantonese, English, Japanese, Korean | Core ML; Fluid conversion targets ANE | Int8 pack is about 228 MB and reports roughly 0.32 GB peak RAM in its own test | Source MIT; weights use the FunASR model agreement |
| Moonshine | CPU-oriented low-footprint streaming experiment | True streaming models available | English plus selected language-specific models | Swift + ONNX Runtime, shipped Apple builds are CPU-only | Tiny 34M, small 123M, medium 245M parameters | Mostly MIT, with documented exceptions for legacy models |

### Whisper family

OpenAI's reference Whisper has 39M, 74M, 244M, 769M and 1.55B parameter tiers, plus the 809M `turbo` model. Its reference decoder works on sliding 30-second windows. Live dictation is therefore implemented by the surrounding runtime through chunking, overlap, voice activity detection and stabilization rather than by a native streaming decoder. [OpenAI Whisper README](https://github.com/openai/whisper/blob/main/README.md) and [Whisper model card](https://github.com/openai/whisper/blob/main/model-card.md)

WhisperKit is the best first Whisper integration for Omil because it is Swift and Core ML rather than a C++ bridge. Its model catalog and APIs already cover model download, microphone input, VAD-bounded decoding, timestamps, language detection and prompts. The Argmax package declares iOS 16 and macOS 13 as its minimum Apple platforms. [Argmax OSS package](https://github.com/argmaxinc/argmax-oss-swift/blob/main/Package.swift), [base.en model files](https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-base.en), and [small.en model files](https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-small.en)

`whisper.cpp` remains a useful independent baseline. Its published disk and approximate memory figures are tiny 75 MiB and 273 MB, base 142 MiB and 388 MB, small 466 MiB and 852 MB, medium 1.5 GiB and 2.1 GB, and large 2.9 GiB and 3.9 GB. Its Core ML encoder path reports more than a 3x speedup over CPU-only inference. These figures are project measurements, not Omil release guarantees. [whisper.cpp](https://github.com/ggml-org/whisper.cpp/blob/master/README.md)

### FluidAudio and Parakeet

FluidAudio is the most relevant non-Whisper Swift stack. It packages Core ML speech models with VAD, inverse text normalization and online or offline diarization. Its current package requires iOS 17 or macOS 14. [FluidAudio README](https://github.com/FluidInference/FluidAudio/blob/main/README.md) and [Package.swift](https://github.com/FluidInference/FluidAudio/blob/main/Package.swift)

The two Parakeet variants serve different products:

- Parakeet EOU 120M is English, streaming and end-of-utterance aware. It is the candidate for live dictation partials.
- Parakeet TDT v3 0.6B is utterance or batch oriented. NVIDIA's card lists 25 European languages, punctuation, capitalization, automatic language identification and word or segment timestamps. It is the candidate for a quality-first final pass. [Parakeet TDT v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)

FluidAudio's own M2 benchmark shows the real streaming tradeoff: 320 ms chunks produced 4.88% average WER at 19.25 times real time, while 160 ms chunks produced 8.23% WER at 5.78 times real time. Its cold-load table reports about 3.36 seconds for the encoder on an iPhone 16 Pro Max and 4.40 seconds on an iPhone 13, compared with about 162 ms warm on the newer device. These results justify prewarming, and they show why smaller chunks should not automatically be treated as better. [FluidAudio benchmarks](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md)

Do not use the aggregate size of a Hugging Face repository as the installed model size. Repositories may contain multiple precision variants and auxiliary models. Record the exact CDN manifest size and compiled size for the variant Omil ships.

### SenseVoice

The released SenseVoiceSmall checkpoint is a 234M-parameter non-autoregressive model for Mandarin, Cantonese, English, Japanese and Korean. Direct inference accepts up to 30 seconds; longer audio requires VAD and bounded windows. Punctuation, inverse text normalization and diarization use additional processing or models. [SenseVoice repository](https://github.com/QwenAudio/SenseVoice)

FluidAudio's converted int8 package lists roughly 225 MB for the main model plus a small preprocessor and reports about 0.32 GB peak RAM on its test setup. This makes it a credible optional CJK pack, but it should not become the general multilingual default without Omil's own accuracy tests. [FluidAudio SenseVoice Core ML card](https://huggingface.co/FluidInference/sensevoice-small-coreml/blob/main/README.md)

SenseVoice code and weights have different licensing surfaces. The source repository is MIT, while the model card points to the FunASR model license and attribution conditions. Product counsel or a deliberate license review should approve the weights before distribution.

### Moonshine

Moonshine now offers true streaming models for Apple platforms, including compact English models and several language-specific variants. Its smallest English model is 34M parameters. It is worth benchmarking on older devices where a small CPU model might beat a larger Core ML graph in startup time. [Moonshine models](https://github.com/moonshine-ai/moonshine/blob/main/docs/models/available-models.md) and [Moonshine Swift](https://github.com/moonshine-ai/moonshine-swift)

It is not the primary ANE recommendation. Moonshine's official execution-provider note says its shipped builds run CPU-only. Its minimal ONNX Runtime build does not include the Core ML execution provider on iOS. [Moonshine execution providers](https://github.com/moonshine-ai/moonshine/blob/main/docs/execution-providers.md)

## Device tiers and automatic selection

The alpha should use a recommended configuration and an explicit advanced model override. Automatic selection and onboarding benchmarks are later work, once multiple configurations qualify. Keep speech model choice independent of cleanup mode. Changing speed preference must not silently remove correction capability; unavailable cleanup requires a visible fallback or abstention state.

A chip-name allowlist will age badly and does not capture memory pressure, thermal state, locale availability or Core ML operator placement.

Eligibility checks now, and automatic selection later, should consider:

1. OS API and locale availability.
2. Installed and free storage.
3. `ProcessInfo.physicalMemory`, current thermal state and Low Power Mode.
4. Model initialization success and peak resident memory.
5. A short cold and warm transcription probe using a bundled, non-user audio sample.
6. The user's priority: fastest live text, best final quality or smallest download.
7. Whether both speech and cleanup backends can complete in the intended foreground/background lifecycle.

The following are starting policies to validate, not promises about every device:

| Device budget | Initial policy |
| --- | --- |
| OS 26 with supported Apple speech locale | Apple speech first, regardless of marketing chip tier; use runtime availability |
| About 4 GB memory or high memory pressure | Probe system speech or a compact custom model; measure separately which correction capabilities fit |
| About 6 GB memory | Parakeet EOU for English or Whisper base/small; unload ASR before any optional text model |
| 8 GB or more | Consider Parakeet TDT, Whisper small or compressed Turbo and a sequential small cleanup model |
| Apple-silicon Mac with 16 GB or more | Allow larger quality-first models, but still benchmark power and latency |

On constrained mobile devices, compare sequential loading with keeping eligible models warm. Sequential loading can avoid memory pressure but adds load latency after release; it is not automatically the best policy. Measure peak footprint, startup, jetsam, thermals, and total insertion delay before allowing concurrent residency or promising speed. Physical RAM is not the app's available memory budget.

Present model choices in product language such as `System`, `Live English`, `European multilingual`, `Broad multilingual` and `CJK compact`. Show download size, installed size, supported languages and an honest speed label. Avoid exposing repository names as the main user decision.

## Streaming, endpointing and finalization

Streaming affects perceived quality as much as model WER. Omil needs separate partial and final states:

- Partial text can change. It should be visually marked as unstable and never sent into another app.
- Treat a segment as final when its backend finalizes it. A VAD endpoint is a signal to finalize, not proof that the recognizer has finished revising text.
- Initially run cleanup after session finalization. Keep prior clauses and candidates through the session so a correction after a pause can refer backward across ASR segments.
- Stable ASR text does not make user intent final. The user can still say "keep the original" before ending the dictation session.
- A full-audio second ASR pass is an optional experiment. Include its cost in stop-to-insertion latency before adopting it.

Use a ring buffer so endpointing can retain a small amount of audio before speech onset and after silence. Keep timestamps in the raw token graph. They help disambiguate restarts, repeated phrases and whether a correction cue belongs to the current clause.

Silero VAD is a credible fallback when the selected recognizer does not provide endpointing. The project is MIT-licensed, supports 8 kHz and 16 kHz audio, is about 2 MB in its JIT form and is designed for streaming chunks. FluidAudio already packages a Core ML conversion, which avoids adding a second foreign runtime. [Silero VAD](https://github.com/snakers4/silero-vad)

Prefer punctuation and capitalization produced by the selected ASR model, then normalize consistently. Parakeet TDT already emits both. Whisper predicts punctuation as text. A separate punctuation model adds latency and another source of changes, so add one only when benchmark data shows a clear need.

Diarization is not required for personal push-to-talk dictation. Keep it out of the first release. It becomes useful for meetings and imported recordings, where it should be a separate mode with different memory, battery and consent expectations. FluidAudio has native diarization components that can be evaluated later. Do not silently run speaker embeddings for ordinary dictation.

## Semantic self-correction and proofreading

### A hybrid is the leading hypothesis to test

Speech repair is usually represented as a reparandum, an optional interruption cue such as `sorry` or `I mean`, and a repair. Incremental repair research detects the onset of a repair, then aligns it with the span to replace. This structure fits deterministic processing, but finding the exact earlier span can require semantics. [Heeman and Allen's repair model](https://aclanthology.org/P93-1007/) and [Detecting speech repairs incrementally](https://aclanthology.org/C10-1154/)

Rules can handle narrowly specified, typed corrections:

- `Tuesday, sorry, Wednesday`
- `send 42, no, 21`
- `to Alice, I mean, Alicia`

They can become brittle with restarts, embedded clauses, quoted speech, and changes in word order. A language model may improve semantic scope selection but can also change meaning incorrectly. Compare rules, structured model proposals, and a hybrid using the same validator and held-out recordings. The proposed hybrid is:

1. Detect possible cues such as `sorry`, `no`, `I mean`, `rather`, `wait`, `actually` and `keep`. Their presence alone does not authorize an edit.
2. Use token types and timing to propose the nearest compatible reparandum. Numbers replace numbers, dates replace dates and named-entity alternatives remain in the same slot.
3. Apply obvious repairs and repeated-fragment deletion deterministically.
4. Ask a local language model only to select spans and edit types for ambiguous cases.
5. Validate references, correction scope, negation, subject/value associations, unaffected clauses, and dependencies before applying an edit. Abstain or offer a suggestion when scope is ambiguous.

The language model should return a constrained structure, for example:

```json
{
  "snapshotId": "snapshot-7",
  "edits": [
    {
      "editId": "edit-1",
      "op": "replaceFromSource",
      "targetTokenIds": ["token-3"],
      "sourceTokenIds": ["token-5"],
      "cueTokenIds": ["token-4"],
      "candidateId": "candidate-21",
      "dependsOn": []
    }
  ]
}
```

This illustrative proposal covers only the value replacement; any removal of cue or repair text requires its own validated target span. Allowed operations include scoped deletion, copying identified source/alternative spans, approved normalization, explicitly requested snippet expansion, and reversal or selection of an earlier candidate. A proposed reference to an ASR alternative must identify its hypothesis and segment, not just a matching word elsewhere.

Source membership does not establish semantic correctness. `Do not send 42. Send 21.` can incorrectly become `Send 42.` without introducing a new token. Add negative tests for deleting negation, moving values between subjects, and removing unrelated clauses. These checks reduce errors; they do not constitute a general proof of intent preservation. A model's self-reported confidence is not a calibrated acceptance probability.

Represent `twenty-one -> 21` as a locale-aware normalization operation whose result the validator can recompute from source tokens and a versioned rule. Apply the same discipline to dates, units, punctuation, and confirmed dictionary substitutions. Membership in the dictionary alone is insufficient evidence for a replacement. Reject unsupported values and preserve original wording on ambiguous edits.

### Required correction behavior

For:

```text
make it 42, sorry 21
```

the cue `sorry` starts a repair. The nearest compatible slot is the number `42`, and the repair provides `21`. The result is:

```text
make it 21
```

For:

```text
make it 42, sorry 21, no no keep it 42
```

the first repair creates `42 -> 21`. The later, more recent repair explicitly refers to the earlier candidate and reverses the edit. The result is:

```text
make it 42
```

Retain the original transcript and candidate history after each proposed repair. In this example the final value is repeated, but `make it 42, sorry 21, keep the original` requires the earlier candidate to resolve the reference. Test both forms, including a long pause or finalized ASR segment before the reversal. Recency, scope, explicit cue type, and candidate identity all contribute to the decision.

### Filler removal and polishing modes

Offer at least three user-facing cleanup levels:

- `Verbatim` preserves recognizer output with optional light punctuation. Document that it cannot restore fillers, restarts, or corrections the recognizer already omitted.
- `Clean` removes unambiguous fillers, repeated fragments and explicit corrections.
- `Polish`, a later opt-in feature, also fixes local grammar and sentence flow while preserving critical values and meaning.

Do not delete every occurrence of `like`, `well`, `right` or `so`. These can be lexical content. Use position, pauses, and surrounding syntax, and favor preserving wording over deleting meaning. Protect numbers, names, and negation by default; an explicit supported correction may replace them. Cleanup behavior remains independent of speech model selection.

### Local cleanup model choices

On supported Apple Intelligence devices, the Foundation Models framework is the first cleanup model to evaluate. Apple describes a built-in on-device model, optimized for tasks such as extraction, summarization and classification, with guided generation and no model added to the app bundle. Availability depends on hardware, language, region and whether the system model is ready, so Omil must check it at runtime. [Apple Foundation Models session](https://developer.apple.com/videos/play/wwdc2025/286/) and [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)

Apple lists supported Apple Intelligence devices starting with iPhone 15 Pro and iPhone 16 models, iPads with M1 or later or A17 Pro, and Apple-silicon Macs. The system models also consume device storage independently of Omil. [Apple Intelligence requirements](https://support.apple.com/en-by/121115)

For unsupported devices, Qwen3-0.6B is a reasonable research baseline. It has 0.6B parameters, a 32K context window and Apache 2.0 weights, and MLX Swift LM supports quantized models and grammar-constrained JSON or EBNF output. A 4-bit 0.6B model has roughly 300 MB of raw quantized weights before metadata, tokenizer and runtime overhead. Actual peak memory will be higher and must be measured. [Qwen3-0.6B](https://huggingface.co/Qwen/Qwen3-0.6B) and [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm)

Whether the first release needs a language model is an empirical decision in milestone one. Rules may cover high-precision cases, but they have not yet demonstrated Omil's broader correction requirement. Compare correction accuracy, coverage, harmful edits, abstentions, startup, memory, and energy on the target devices. If neither rules nor an eligible local model meets the bar, report the unsupported capability rather than silently weakening Clean mode.

## Privacy, permissions and review

Apple says data processed only on-device and never transmitted is not considered "collected" for App Store privacy disclosures. If Omil adds crash attachments, analytics containing transcript fragments, optional sync or cloud model APIs later, those features change the disclosure. [App privacy details](https://developer.apple.com/app-store/app-privacy-details/)

The product should still provide:

- A clear microphone purpose string.
- Explicit consent before recording.
- A persistent visible recording indicator, with an optional audible start or stop cue.
- A one-tap way to delete recordings, transcripts, downloaded models and learned vocabulary.
- A setting that controls whether raw audio is retained. The privacy-first default is not to retain it after finalization.
- A plain statement that transcription and cleanup run locally, plus an airplane-mode verification screen for users who want proof.

App Review guideline 2.5.14 requires explicit user consent and a clear visual or audible indication when recording. Guideline 2.5.4 limits background modes to their intended purposes. Guideline 2.5.2 prohibits downloading executable code, but Apple separately supports downloaded Core ML model data. Keep model packs as data consumed by shipped runtimes, pin their hashes and do not use them to deliver new executable behavior. [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) and [NSMicrophoneUsageDescription](https://developer.apple.com/documentation/BundleResources/Information-Property-List/NSMicrophoneUsageDescription)

Review all licenses per shipped artifact, not just per repository. At minimum:

- OpenAI Whisper code and weights are MIT.
- WhisperKit and whisper.cpp code are MIT.
- FluidAudio code is Apache 2.0.
- Parakeet TDT v3 weights are CC BY 4.0 and require attribution.
- Qwen3-0.6B is Apache 2.0.
- SenseVoice source and model licenses differ and need a specific review.
- Moonshine documents exceptions for some legacy community models, so each selected checkpoint needs its own license record.

Include model name, version, source URL, license, conversion commit and file hash in a machine-readable manifest and in the app's acknowledgements.

## Benchmark plan

Do not choose the default model from vendor real-time factors or one public WER number. Different projects use different hardware, decoding settings, chunk sizes, language mixes and preprocessing.

### Evaluation sets

Use three layers:

1. Standard ASR sets for comparison, including LibriSpeech for English, FLEURS for multilingual coverage and AMI for conversational or meeting speech. [LibriSpeech](https://www.openslr.org/12), [FLEURS paper](https://arxiv.org/abs/2205.12446), and [AMI corpus](https://groups.inf.ed.ac.uk/ami/corpus/)
2. A consented Omil set recorded on actual iPhones, iPads, built-in Mac microphones, AirPods and common Bluetooth headsets. Cover accents, room noise, far-field speech and movement.
3. A locked semantic-repair set with numbers, dates, names, URLs, commands, repetitions, nested repairs, reversals, negation and quoted speech.

Begin collecting the recorded Omil set in milestone one. Pair each recording with a human transcript, intended output, protected spans, and acceptable abstention behavior. Separate development examples from held-out examples and speakers. Run cleanup on both human transcripts and actual backend output to isolate recognition loss from correction errors. Add recordings where cues or rejected values disappear from ASR output; a text-only test cannot reveal that failure.

Include adversarial examples such as:

- `Call Sam, sorry, call Pam.`
- `Schedule it for fifteen, no, fifty minutes.`
- `The password is A B, no, I said the words "A B".`
- `Do not remove the word um.`
- `Keep version 1.2, sorry 1.3, wait, keep 1.2.`
- `Email john at example dot com, no, jane at example dot com.`
- `Do not send 42. Send 21.` Preserve both clauses; `Send 42.` is invalid despite containing only source words.
- `Send Alice 42 and Bob 21, actually Bob 24.` Change Bob's value only.
- `She said "sorry, make it 21".` Preserve the quoted content.
- `Make it 42, sorry 21`, a pause, then `keep the original` in the same session.
- Already-clean speech, ordinary apologies, and ambiguous alternatives that must remain unresolved.

### Metrics

Measure recognition and cleanup separately.

For ASR:

- WER and CER by language, accent and acoustic condition.
- Exact accuracy for numbers, dates, names, URLs and user vocabulary.
- Preservation of repair markers, rejected values, negation, and clause boundaries needed by cleanup.
- Punctuation F1 and capitalization accuracy.
- Hallucination rate on silence, noise and music.
- Time to first partial, partial correction churn, endpoint delay and time to stable final text.
- Cold and warm model load, real-time factor, peak resident memory, download size, installed size, energy impact and thermal throttling.

For cleanup:

- Reparandum and repair span precision, recall and F1.
- Exact final-text match on the locked correction set.
- Over-edit rate and false deletion rate.
- Critical-token preservation for digits, names, code, URLs and negation.
- Invented-token rate.
- Correction coverage and abstention rate alongside precision, so doing nothing does not pass as successful cleanup.
- Incorrect negation, subject/value reassignment, and unintended changes to unaffected clauses.
- Meaning-preservation judgments on a blinded human sample.

For the end-to-end product:

- Time from hotkey or tap to recording state.
- Time from button release to clipboard or insertion.
- Crash and jetsam rate.
- Battery drain during repeated five-minute sessions.
- User corrections per 100 dictated words.
- Insertion success and duplicate/stale delivery rate through focus changes, selection changes, typing, cancellation, keyboard restarts, and retries.
- Scoped undo correctness and preservation of clipboard writes made by the user during processing.

Run on physical minimum, middle, and recent high-end devices across supported OS versions. Test in airplane mode after model installation and inspect app network traffic separately from system asset downloads. Record exact device, model hash or system backend/OS identity, conversion version, decoder settings, cleanup configuration, chunk size, execution state, and thermal state.

Measure stop-to-visible-insertion latency, including ASR finalization, cleanup, interprocess coordination, and delivery. Separate cold model initialization, first asset preparation, warm inference, background sessions, and utterance-length groups such as 5-30 seconds and longer recordings. Initial timings are exploratory. For an alpha p95 decision, collect at least 100 completed dictations per claimed device/configuration/state group, report sample counts and tail uncertainty, and also report failures/timeouts rather than excluding them from the experience assessment. Do not infer a stable p95 from five warm runs.

The product plan's 800 ms Mac and 1.5 second iPhone warm targets are provisional. Ratify or revise latency and correction precision/coverage thresholds after baseline measurement, then freeze them before held-out alpha evaluation. No known harmful critical-value, negation, or scope error should pass the locked regression suite. Zero observed failures in that suite is not proof of universal correctness. Keep app-controlled model updates behind regression checks; system model updates require revalidation and a documented fallback because Omil cannot pin Apple's model indefinitely.

## Delivery sequence

### Milestone 1: demonstrate correction and both platform workflows

- One shared package, thin platform adapters, Apple Speech as the initial candidate, and one open comparison backend.
- Recorded correction evaluation comparing rules, local-model edits, and the hybrid on human and actual ASR transcripts.
- Immutable snapshot/token identities, normalization operations, semantic-scope checks, abstention, and a replayable edit journal.
- Mac push-to-talk through guarded insertion and scoped undo, including destination and clipboard races.
- iPhone app-owned recording and local inference coordinated with keyboard insertion, exercised across lifecycle states. Validate iPad separately.
- A benchmark report and device/locale/execution-state capability matrix, with failures and proposed alpha thresholds.

Passing the two supplied examples is necessary but insufficient. Semantic correction and mobile feasibility belong in this first milestone. No duration estimate is committed before prototype complexity and available test devices are known.

### Supported alpha workflows

Use milestone-one results to choose devices, locales, backend configurations, and Mac/mobile release order. Ship the verified interaction with explicit recovery states, independent cleanup settings, and advanced model override where supported. Add a personal dictionary and basic formatting only with scope and normalization tests. The product plan contains the alpha scope.

### Later expansion

Add automatic model selection, more downloadable packs, additional system entry points, snippets, and opt-in Polish mode when justified by measured gaps. Meeting transcription, diarization, team features, and cloud services remain outside the initial scope.

## Decision summary

The available runtimes provide credible starting points, but Omil has not yet established correction quality, background inference feasibility, or delivery reliability on its target devices.

1. Test a containing-app recording session coordinated with a keyboard before deciding the mobile interaction must use copy/paste.
2. Evaluate Apple Speech and one comparison backend on both recognition quality and retention of correction evidence.
3. Compare rules, local-model edits, and their combination early. Source references, scoped checks, normalization rules, and abstention support inspection and error handling; they do not guarantee semantic correctness.
4. Let measured correction, insertion, and lifecycle results determine the device floor, models, and release order.
