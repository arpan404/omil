# Third-party acknowledgements

Omil has **zero SwiftPM dependencies**. All recognition and UI uses Apple
system frameworks (Speech, AVFAudio/AVFoundation, SwiftUI, AppKit/UIKit).

## System speech backends (no bundled weights)

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
