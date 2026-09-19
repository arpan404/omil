# Omil product and build plan

Status: revised working proposal after architecture review, September 19, 2026. No device benchmarks or feasibility prototypes have run yet.

## The product

Omil is local-first dictation for Apple devices. It turns natural, messy speech into text the user intended to write. Audio and text stay on the device by default, the app works offline after model assets are installed, and every cleanup is reversible.

The first release should do one job very well:

> Hold a shortcut, speak naturally, release, and get faithful cleaned text in the current text field.

"Faithful" matters. Omil may remove disfluencies, resolve explicit self-corrections, restore punctuation, and apply requested formatting. It must not invent facts or casually rewrite the user's meaning.

The source-backed technical survey is in [on-device-speech-stack.md](research/on-device-speech-stack.md).

The first milestone must demonstrate correction of recorded natural speech, reliable Mac insertion, and an iPhone recording-to-keyboard round trip with local inference. These results determine the minimum devices, model choices, and release order. Mac-first delivery is a working preference, subject to those results.

## What "like Wispr Flow" means

Wispr Flow's current product combines dictation in other apps, filler removal, punctuation, backtracking over spoken corrections, lists, a personal dictionary, snippets, writing styles, app context, and more than 100 languages. Its own help center says transcription requires an internet connection and processes dictated audio in the cloud. Omil should copy the interaction lessons, not its service architecture.

Sources: [Wispr Flow feature overview](https://try.wisprflow.ai/), [Wispr Flow product behavior](https://docs.wisprflow.ai/articles/2772472373-what-is-flow), [Wispr Flow security and data overview](https://docs.wisprflow.ai/articles/3467817258-security-and-compliance-faq).

| Capability | Omil priority | Product stance |
| --- | --- | --- |
| Dictate into other apps | Early feasibility test on both platforms | Global shortcut on Mac; app-owned recording coordinated with a keyboard on iPhone and iPad |
| Filler and repetition cleanup | MVP | Conservative by default, with visible edits |
| Spoken self-corrections | MVP | Grounded edit history, including reversals to an earlier choice |
| Punctuation and lists | MVP | Explicit formatting operations with literal and quoted speech preserved |
| Personal dictionary | Mac alpha | Local, user-controlled, no silent learning |
| Snippets | After core dictation | Exact static expansion before any stylistic rewrite |
| Per-app writing style | Later | Opt-in Polish mode, separate from faithful Clean mode |
| App context | Later on Mac | Per-app consent and a narrow nearby-text window |
| 100+ languages | Not an early promise | Publish only locales that pass Omil's ASR and correction tests |
| Offline operation | Core differentiator | No network fallback; model downloads are explicit |
| Account and sync | Optional later | No account required; local history first |

## Product decisions

### Prove both platform workflows before fixing the release order

Mac can support the full workflow: a global push-to-talk shortcut, microphone capture in the background, and insertion into the focused field after the user grants Accessibility permission.

Distribute the full Mac product as a Developer ID signed and notarized app outside the Mac App Store. Accessibility-based control of other apps conflicts with the App Sandbox model. A later Mac App Store edition can use clipboard handoff or narrower integrations, but it should not define the architecture of the main product.

Sources: [Apple App Sandbox guidance](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox), [Accessibility trust API](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions).

iPhone and iPad require separate recording and keyboard processes. Apple states that custom keyboard extensions have no microphone access, including keyboards with Full Access. This restricts where recording runs; it does not establish that a keyboard-driven dictation experience is impossible. Wispr documents starting dictation from its iPhone keyboard and receiving the result in the current text field. Its instructions establish the interaction, without establishing its internal implementation or the feasibility of local inference for Omil.

The first mobile prototype should test this proposed architecture:

- The containing Omil app owns microphone capture and local inference during an explicitly activated recording session.
- A lightweight keyboard coordinates start/stop requests with that session and inserts its matching completed result through `textDocumentProxy`. It does not load speech or cleanup models.
- Public App Group communication shares session IDs, commands, and result state. Validate permissions, Full Access requirements, process lifecycle, and the supported activation path on actual devices. Shared storage alone cannot wake a suspended app.
- An `AudioRecordingIntent` is an alternative session entry point. Apple requires an active Live Activity while this records on iOS and iPadOS. Test this route before building every widget and shortcut.
- Session IDs and acknowledgement state prevent stale or duplicate insertion after app switches, retries, cancellation, or keyboard restarts.

Test while another app is foregrounded, after idle time, during interruption and resumption, with the device locked, and after the containing app is terminated. Recording permission and an active audio session do not prove that the selected inference backend can run in every background state. Verify the complete ASR and cleanup path per supported OS and device.

In-app recording with copy/share remains a fallback. Do not reduce the mobile product to that workflow until the session-and-keyboard experiment identifies the actual limit. Report required reactivation and background restrictions explicitly.

Sources: [Apple custom keyboard restrictions](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard), [Wispr's iPhone workflow](https://docs.wisprflow.ai/articles/6409258247-starting-your-first-dictation), [AudioRecordingIntent](https://developer.apple.com/documentation/appintents/audiorecordingintent).

### Keep transcription choice separate from cleanup behavior

Start with one recommended speech backend and an explicit advanced override for the comparison backend. Select eligible configurations using OS, locale, installed assets, and measured device results. Automatic onboarding benchmarks and a larger model catalog can follow when multiple configurations justify them.

Transcription settings choose the engine and its measured speed, size, and accuracy tradeoffs. Cleanup settings independently choose Verbatim, Clean, or later Polish. A faster transcription setting must not silently disable correction handling. If the selected cleanup capability is unavailable, show that state and preserve the transcript or apply only validated edits.

Future Fast and Accurate presets may select different speech configurations once benchmarks justify those labels. Keep the selected cleanup mode unchanged. Advanced settings should expose the actual model, version, language support, and required download so users can make the choice they asked for.

### Evaluate Apple system models as the primary candidate

For OS 26 and newer, start evaluation with `SpeechAnalyzer` and `SpeechTranscriber`:

- It runs entirely on device.
- It supports live volatile results followed by final results.
- Results can carry audio time ranges.
- Apple stores the language model in system storage, outside the app's memory budget, and updates it independently.
- `AssetInventory` handles optional language asset downloads.

Use `DictationTranscriber` where `SpeechTranscriber` does not support a locale or device. Add an open ASR backend only after it wins our benchmark for a real user segment. Bundling Whisper on day one would add model downloads, memory pressure, battery work, and another decoder to maintain before we know that it improves the product.

Add one comparison backend to the initial prototype, chosen for the first target language and devices. The shortlist is:

- FluidAudio Parakeet EOU 120M for low-latency English streaming on iOS 17 and newer.
- FluidAudio Parakeet TDT 0.6B for batch quality and 25 European languages.
- WhisperKit as the broad-language baseline, starting with `base` and `small`, not the largest model that fits.

FluidAudio targets Core ML and the Neural Engine. WhisperKit gives us a mature Swift/Core ML implementation of Whisper and much wider language coverage. Moonshine is CPU-only in its current Apple build, and SenseVoice is best treated as a later specialist for Mandarin, Cantonese, Japanese, Korean, and English.

For custom models, compare eligible Core ML compute configurations in the intended execution state. `.all` is a foreground baseline, not a blanket policy for background mobile inference. Confirm actual operator placement with profiling. OS-specific background execution requirements need validation before enabling a backend for keyboard sessions. Treat the OS 27 Core AI path as a later experiment with an explicit deployment target.

Sources: [SpeechAnalyzer session](https://developer.apple.com/videos/play/wwdc2025/277/), [Core ML compute units](https://developer.apple.com/documentation/coreml/mlcomputeunits), [Core AI model integration](https://developer.apple.com/documentation/foundationmodels/running-a-core-ai-model-in-a-foundation-models-session).

### Compare correction strategies before choosing the implementation

A free-form "rewrite this transcript" prompt is too risky. It can lose names, negate the wrong clause, or make a plausible sentence that the user never said. Pure regular expressions also fail once a correction refers back to an earlier choice.

The leading hypothesis is a hybrid of deterministic rules and a local language model. Compare rules alone, model-proposed edits, and the hybrid against the same recorded evaluation set in the first milestone. Use a common edit validator so the comparison isolates correction quality.

1. Preserve the original recognizer output as immutable, versioned snapshots, including available timing and alternatives. Derived tokenization and normalization must retain links to their sources.
2. Propose filler removals and correction spans using wording, timing, clause structure, and candidate history. Treat "sorry," "no," and "actually" as possible cues rather than commands by themselves.
3. Generate explicit edit operations. Model output references token and candidate IDs in a specific snapshot. It may abstain from an ambiguous repair.
4. Validate source references, correction scope, negation, subject/value associations, and unaffected clauses. Reject unsupported references, conflicting edits, and stale snapshot versions.
5. Apply accepted edits to a derived view. Keep the input, reasons, evidence, and edit dependencies for inspection and undo.

Source grounding limits unsupported additions, but does not guarantee meaning preservation. `Do not send 42. Send 21.` must not become `Send 42.`, even though every output word exists in the source. Preservation checks and a regression corpus are necessary; neither structured generation nor a model's stated confidence proves an edit correct. Preserve wording or offer a suggestion when evidence is insufficient.

Define approved transformations separately from copying source tokens. For example, a locale-aware number rule can map `twenty-one` to `21` while recording the source tokens and rule version. Dates, units, punctuation, confirmed dictionary substitutions, and explicitly invoked snippets need their own scoped operations. Dictionary membership alone does not authorize inserting a name anywhere in a transcript.

Evaluate the on-device Foundation Models backend where available and one small local fallback only if required by the device floor. A deterministic fallback may apply high-precision edits, but broader correction capability must be demonstrated before it is advertised on a device.

The intended state transitions for the motivating examples are:

| Spoken transcript | Candidate history | Final text |
| --- | --- | --- |
| `make it 42` | `42` | `Make it 42.` |
| `make it 42, sorry 21` | `42 -> 21` | `Make it 21.` |
| `make it 42, sorry 21, no no keep it 42` | `42 -> 21 -> select 42` | `Make it 42.` |

Retain candidate history through the whole dictation session, including across pauses and finalized ASR segments. It is especially necessary when a speaker says "keep the original" without repeating its value. ASR finalization means recognized text is stable; it does not mean the user cannot correct that text later in the same session.

Source: [Apple Foundation Models and guided generation](https://developer.apple.com/documentation/foundationmodels).

## Experience design

### The core interaction

1. The user focuses a text field and holds the Omil shortcut. Omil records the intended destination and selection when those are inspectable.
2. A compact recording indicator appears with a live, deliberately labeled draft transcript.
3. Releasing the shortcut finalizes ASR and cleanup.
4. Omil revalidates the destination, selection, and relevant content before inserting the cleaned result. If they changed or cannot be safely verified, retain the result for explicit insertion.
5. An insertion receipt records the affected range, prior selected text, and supported undo operation. Undo reverses only Omil's insertion when the destination still matches. It must not restore an old whole-field snapshot over later typing.

The live transcript can change because `SpeechTranscriber` emits volatile results. Show it as a draft. Initially run cleanup over the finalized session after release; measure whether incremental cleanup is needed. Keep earlier clauses available for later corrections.

Test app switching, cursor movement, concurrent typing, selection changes, canceled sessions, and retries during processing. When a host cannot provide reliable insertion or undo semantics, use an explicit copy/paste action and keep the result available. Restoring raw transcript text inside Omil is independent of undoing edits in another app.

### Cleanup modes

- Verbatim applies no cleanup beyond optional punctuation and capitalization to the recognizer output. It cannot recover fillers or corrections that the ASR already omitted; measure this limitation per backend.
- Clean is the default. It removes safe fillers, repetitions, and resolved false starts.
- Polish fixes grammar and applies an app-specific style. It is opt-in because it may change phrasing.

Keep "Clean" and "Polish" separate. The user should know when Omil is editing delivery and when it is rewriting prose.

### Trust controls

- Show a permanent local/offline status in the recorder and model screen.
- Offer Raw, Cleaned, and Diff views for every recent dictation.
- Make raw audio retention off by default. Delete the temporary buffer after finalization unless the user opts into audio history.
- Keep text history off by default or give it a short, visible retention period.
- Never read surrounding text on Mac unless Context Awareness is enabled for that app.
- Exclude password fields and sensitive apps. Do not fall back to clipboard insertion silently.
- If insertion needs the clipboard, preserve its supported prior contents. Restore them only if the clipboard still contains Omil's write and its change count matches. Never overwrite a newer user copy. Test paste-consumption timing per host; a fixed delay alone is not proof that pasting finished.
- Do not require an account for local dictation.

## Feature scope

### Version 0.1, technical proof

- One shared Swift package, a minimal recorder, and thin Mac and mobile integrations.
- Apple Speech as the primary ASR candidate and one comparison backend. Adapt input audio to each backend's supported format.
- A consented recorded corpus covering replacements, reversals, pauses, quoted corrections, ordinary apologies, numbers, names, negation, and unchanged speech. Maintain separate development and held-out examples.
- Compare rules, local-model edits, and the hybrid on human transcripts first, then actual ASR output. Measure loss of correction cues and alternatives during recognition.
- A Mac shortcut-to-insertion demonstration, including destination changes and scoped undo.
- An iPhone app-owned recording-to-keyboard round trip with local ASR and cleanup while another app is foregrounded. Record activation, idle, interruption, cancellation, duplicate delivery, suspension, and termination behavior. Check iPad behavior separately.
- A reproducible benchmark report covering cold/warm latency, accuracy, memory, energy, thermal state, and offline operation. A dedicated benchmark UI is optional.

Exit condition: all three demonstrations have measured results and a written capability matrix. The required `42 -> 21` and `42 -> 21 -> 42` cases must pass alongside held-out semantic cases and no-change controls. Report failures and abstentions separately. A foreground mobile demo or three text-only examples cannot satisfy this milestone. Choose supported devices and quality thresholds from the baseline before approving an alpha; if keyboard coordination fails, document why and decide explicitly whether the fallback workflow meets the product goal.

### Version 0.2, Mac alpha

- Menu bar app and configurable hold-to-talk shortcut.
- Focused-field insertion with clear Accessibility onboarding.
- One recommended transcription configuration, an advanced override where supported, and an independent cleanup setting.
- Verbatim and Clean output.
- Personal dictionary for names, acronyms, and product terms.
- Spoken formatting commands: new line, new paragraph, bullet list, numbered list, literal punctuation.
- Raw/Cleaned/Diff history with undo and configurable retention.
- English first. Add another locale only when its ASR and correction suites meet the release bar.

### Version 0.3, iPhone and iPad alpha

- Ship the recording/session/keyboard interaction proven in version 0.1, with visible activation and recovery states.
- Add the native recorder and copy/share fallback.
- Add one proven system entry point, then expand to Action button, Control Center, Lock Screen, or Shortcuts where useful. Keep the required Live Activity for recording intents.
- Bind each result to its originating session and acknowledge insertion once.
- Show asset readiness and storage controls for the selected backend. Build a larger model catalog only when additional models qualify.
- Share session state, dictionary, and settings through the verified App Group arrangement. iCloud sync remains optional.

The Mac and mobile alpha order may change based on version 0.1 results. Mobile feasibility is not deferred until version 0.3.

### Version 0.4, quality and personalization

- Opt-in Polish mode using the system foundation model.
- Per-app styles on Mac: concise chat, email, prose, and developer prompt.
- Voice snippets with longest-trigger matching and an explicit conflict UI.
- Conservative app context on Mac, limited to nearby text after per-app consent.
- Automatic learning from corrections only after the user confirms the proposed dictionary entry.
- One benchmark-proven open ASR or cleanup backend if it earns its storage and battery cost.

### Later, not MVP

- Meeting recording, speaker diarization, summaries, and call transcription.
- Team dictionaries, dashboards, or accounts.
- Cross-platform Windows or Android clients.
- Full coding dictation and AST-aware edits.
- Automatic language switching inside one utterance.
- Cloud inference. If it is ever added, make it a separate, explicit mode rather than a quiet fallback.

## Architecture

Use one shared Swift package with thin platform integrations. Start with internal modules for audio, transcription, cleanup, and delivery; split packages only when independent dependencies or ownership justify it.

```text
AVAudioEngine
    -> AudioCapture
    -> TranscriptionBackend
         -> AppleSpeechBackend
         -> OpenASRBackend, optional
    -> TranscriptAssembler
         -> volatile segments for UI
         -> finalized segments for cleanup
    -> CleanupPipeline
         -> Normalizer
         -> FillerAndRepeatRules
         -> CorrectionResolver
         -> Formatter
         -> EditValidator
    -> Delivery
         -> MacFocusedFieldInserter
         -> MobileResultStore
         -> Clipboard/Share
    -> LocalHistory
```

Keep a few explicit contracts:

- `TranscriptionBackend` declares input format and capabilities, prepares assets, and emits identified segment revisions with finality, timing, and alternatives when available.
- `TranscriptCleaner` takes an immutable snapshot and returns proposed edits plus abstentions. Validation produces a derived text view and an edit journal.
- `TextDestination` prepares and revalidates an insertion target, commits once, and returns a receipt describing supported undo behavior.
- Platform adapters own recording lifecycle, shortcuts, keyboard coordination, permissions, and interruption handling.

Use the backend's negotiated audio format. For Apple Speech, query `bestAvailableAudioFormat` after asset readiness. Keep time mapping through conversion and any VAD windows; do not assume every recognizer accepts 16 kHz mono. [Apple audio format negotiation](https://developer.apple.com/documentation/speech/speechanalyzer/bestavailableaudioformat%28compatiblewith%3A%29).

The initial persisted data contract is conceptual and should be exercised in the prototype:

| Record | Required identity and evidence |
| --- | --- |
| Transcript snapshot | Session ID, snapshot ID, revision, immutable recognizer output, backend/configuration identity, segment revisions, token sequence |
| Token reference | Snapshot ID and stable token ID; unchanged tokens retain IDs across revisions, changed tokens get new IDs; timing and original text remain attached |
| Alternative hypothesis | Hypothesis ID, source audio/segment range, its own token IDs, recognizer ranking when available; alternatives are not interchangeable words without context |
| Proposed edit | Edit ID, exact input snapshot, operation, ordered target token IDs, evidence token IDs, correction candidate and dependency IDs, reason, and rule/model version |
| Normalization edit | Source tokens, locale, rule ID/version, derived output; validator recomputes approved transformations |
| Edit journal | Accepted edits and dependency order, rejected proposals, abstentions, selected candidates, derived view revision |
| Insertion receipt | Session and destination identity, relevant selection/content precondition, inserted range and replaced selection when available, commit state, undo capability |

Operations include scoped deletion, copying an explicitly identified source or alternative span, approved normalization, explicit snippet expansion, and reverting an edit or selecting an earlier candidate. Store IDs and evidence that can survive serialization. `String.Index` can be a temporary implementation detail within one string snapshot; it is not the persisted identity of an edit.

Invalidate or explicitly rebase proposals when their snapshot changes. Undo or replay must account for dependent edits. Source membership and confidence scores are evidence for validation, not proof of semantic correctness. Start with local files or minimal storage for experiments; choose the production history database after retention and keyboard coordination needs are known.

## Model strategy

| Layer | Default | Fallback | Selection rule |
| --- | --- | --- | --- |
| ASR | `SpeechTranscriber` evaluation baseline | Probe `DictationTranscriber` and one open comparison backend | Locale, device, execution state, and recorded correction evidence |
| Semantic correction | Rules/model/hybrid comparison in version 0.1 | Validated high-precision edits plus explicit abstention | Held-out meaning preservation and correction accuracy |
| Custom ASR | One prototype comparison, shipping inclusion undecided | Parakeet or WhisperKit candidate | Must improve a defined device/locale segment |
| Custom cleanup model | Optional version 0.1 experiment if the device floor needs it | Qwen3 0.6B candidate | Accuracy, semantic checks, memory, latency, and background viability |

Persist language, cleanup mode, and the user's Automatic or explicit model preference separately. Preserve manual overrides and explain when unavailable. Record the resolved backend, version, rules, and configuration per session for diagnosis and reproducibility.

Model packages need a manifest containing version, languages, size, minimum RAM class, estimated peak memory, license, checksum, and benchmark scores by reference device. Download weights as data only. Do not download executable code, which would conflict with App Store rules.

## Evaluation plan

ASR quality and cleanup quality are separate. A single end-to-end score hides which layer failed.

### ASR metrics

- Word error rate and character error rate by locale, accent, device, and acoustic condition.
- Proper noun and number accuracy.
- Retention of repair cues, rejected values, negation, and clause boundaries needed by cleanup.
- Time to first volatile text, time to stable text, and finalization delay.
- Real-time factor, peak resident memory, package size, battery drain, and thermal state.

### Cleanup metrics

- Exact match for short correction cases.
- Meaning preservation judged against a hand-labeled target.
- Correction resolution accuracy by marker and correction distance.
- Protected-token preservation for names, numbers, URLs, code, negation, and quoted text.
- Unsupported insertion rate. The target is zero for Clean mode.
- Over-edit rate on already clean speech.
- Correction coverage and abstention rate, alongside precision. An engine that changes nothing must not pass solely because it makes no harmful edits.

Build a versioned `CorrectionCorpus` before tuning prompts. Each case stores raw transcript, intended output, protected spans, allowed alternative outputs, locale, and tags. Include at least:

- Replacement: "Tuesday, sorry, Wednesday."
- Reversal: "42, sorry 21, no, keep 42."
- Full restart: "Send it to Sam, scratch that, send it to Priya."
- Negation: "Do not, actually, do send it."
- Non-correction uses: "I am sorry about the delay" and "No worries."
- Ambiguity: "Book it for Tuesday, or maybe Wednesday." This should remain ambiguous rather than silently choose.
- Long-distance reference: "Use the first title... no, go back to the second one."
- Source-grounding counterexample: "Do not send 42. Send 21." Preserve both clauses and reject "Send 42."
- Scope: "Send Alice 42 and Bob 21, actually Bob 24." Change only Bob's value.
- Quoted speech: "She said 'sorry, make it 21.'" Preserve the quotation as content.
- Normalization: "Make it twenty-one" becomes "Make it 21" only through the configured number rule.
- Pause-boundary reversal: "Make it 42, sorry 21" followed by a pause and "keep the original" within the same session.

Record real voices in the first milestone. Pair audio with a human transcript and intended output. Run each cleaner on both human and actual ASR transcripts so recognition loss and cleanup errors can be distinguished. Keep held-out speakers and examples separate from prompt/rule tuning. Pin dataset and configuration versions, publish subgroup counts, and record limitations in the device capability matrix.

## Delivery sequence

1. Produce the version 0.1 correction, Mac insertion, and mobile recording-to-keyboard demonstrations.
2. Use their measured results to select the first devices/locales, correction implementation, execution-state support, and release order.
3. Refine the shared transcript, edit, session, and insertion contracts using those experiments.
4. Ship the supported alpha workflows with explicit limits and recovery paths.
5. Add models, automatic selection, entry points, and personalization only when a demonstrated user need justifies them.

## Release gates

- After required assets are installed, core workflows work offline and send no audio, transcript, or cleanup prompt off device. Test with network disabled and inspect app network traffic separately from OS-managed asset downloads.
- Every Clean-mode edit has a valid source reference or approved transformation, passes scope checks, and leaves unaffected clauses intact. No known harmful negation, subject/value, or unsupported number/name change is accepted in the locked regression suite. Passing the suite is not a universal correctness guarantee.
- Define correction precision, coverage, over-edit, and abstention thresholds from the initial baseline and freeze them before the alpha evaluation. Release remains blocked until those thresholds and sample counts are recorded.
- The user can recover raw text after every cleanup until its retention window expires.
- Provisional latency targets are p95 below 800 ms on the reference Mac and 1.5 seconds on the reference iPhone for warm, 5-30-second dictations using the selected speech backend and Clean mode. Measure from stop/release to visible insertion, including finalization, cleanup, coordination, and delivery. Record device, OS, model configuration, and foreground/background state. Report cold startup, first asset preparation, and longer utterances separately. Ratify or revise these targets after the baseline; they are not measured claims.
- Every supported insertion path handles destination changes, cancellation, retry, newer clipboard writes, and scoped undo without overwriting unrelated user edits or inserting a result twice.
- A 10-minute continuous run has no unbounded memory growth and stays within an agreed thermal envelope.
- Every supported locale has its own filler, correction, number, and punctuation suite.
- Recording always has a visible system-compliant indicator.

## Open decisions to settle with prototypes

- Whether `SpeechTranscriber` accuracy is good enough for the first supported accents and noisy rooms.
- Which of rules, local-model edits, and the hybrid meets correction quality and coverage targets on actual ASR output.
- Whether the mobile app can coordinate local recording, inference, and keyboard insertion across supported background states, and how users reactivate expired sessions.
- Whether direct Accessibility value replacement or simulated paste has broader Mac app compatibility.
- Which devices define the minimum support floor. Do not set this from chip names alone; use measured latency, memory, and thermals.
- Whether to store audio long enough to retry after a process interruption. The privacy-friendly default is no, but reliability may justify a short encrypted crash-recovery window.

## First milestone deliverables

1. A recorded correction corpus, held-out results, and a comparison of rules, local-model edits, and the hybrid.
2. A Mac demonstration with guarded insertion, cancellation, clipboard ownership checks, and scoped undo.
3. An iPhone demonstration connecting app-owned recording and local inference to keyboard insertion, with a lifecycle test report and a separate iPad check.
4. A benchmark report and capability matrix identifying eligible devices, locales, execution states, model choices, remaining failures, and the proposed alpha quality thresholds.

Use a minimal shared package and one primary plus one comparison speech backend. Estimate delivery time after measuring prototype complexity and confirming physical test devices; a one-week commitment is not supported by the current evidence.
