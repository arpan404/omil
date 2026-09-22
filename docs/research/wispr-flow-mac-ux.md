# Wispr Flow Mac UX research

Research date: 2026-09-21

This note documents current Wispr Flow behavior using first-party Wispr pages and Apple documentation. It is a product reference for Omil, not a request to copy Wispr's branding or implementation.

Statements under "Verified" come directly from linked sources. Statements under "Omil direction" are recommendations or inferences. Wispr changes quickly, and some of its own pages disagree about defaults. Those conflicts are called out instead of resolved by guesswork.

## Short version

The strongest part of Flow's Mac experience is a tight loop:

1. Put the cursor where the text belongs.
2. Hold a global shortcut and speak.
3. Get immediate audio and visual confirmation that recording started.
4. Release the shortcut.
5. Wait through a distinct processing state.
6. Receive one finished, cleaned result in the original field.
7. Recover the result through history, copy, paste, or retry if any later step fails.

Flow's current desktop product does not show a live word-by-word dictation transcript. It shows recording feedback, then inserts the completed text after the user stops. [What is Wispr Flow?](https://docs.wisprflow.ai/articles/2772472373-what-is-flow) and [Starting your first dictation](https://docs.wisprflow.ai/articles/6409258247-starting-your-first-dictation)

Omil should reproduce that dependable loop first. The SwiftUI app should own capture, permission UI, session state, insertion, and recovery. The Effect and Bun server should own transcription and cleanup. A live draft can be added later if it measurably helps, but it is not needed for a Flow-like experience.

## The core interaction

### Push-to-talk and hands-free recording

Verified:

- Mac push-to-talk defaults to `Fn`. Setup uses `Ctrl+Option` when no Apple `Fn` key is detected. The user holds the shortcut, speaks after a sound or moving white bars confirm capture, then releases it to process and insert the result. [Starting your first dictation](https://docs.wisprflow.ai/articles/6409258247-starting-your-first-dictation)
- Hands-free recording starts with `Fn+Space`, a rapid double-tap of push-to-talk, or a click on the Flow Bar. The same shortcut or the stop control finishes the session. `Esc` or the cancel control stops without normal insertion. [Use Flow hands-free](https://docs.wisprflow.ai/articles/6391241694-use-flow-hands-free)
- Shortcut bindings are configurable per device. Flow supports up to four bindings for most actions, rejects reserved or duplicate combinations, and also exposes shortcuts for command mode, cancel, paste last transcript, and copy last transcript. [Supported and unsupported keyboard hotkey shortcuts](https://docs.wisprflow.ai/articles/2612050838-Supported-&-Unsupported-Keyboard-Hotkey-Shortcuts)
- Flow ignores new shortcut starts while it is stopping, processing, retrying, or testing the microphone. [Use Flow hands-free](https://docs.wisprflow.ai/articles/6391241694-use-flow-hands-free)

Omil direction:

- Make hold-to-talk the primary action. Keep tap-to-toggle as a separate hands-free mode, not an ambiguous behavior on the same press.
- Preserve the intended destination when recording starts. Revalidate the focused app, field, selection, and surrounding text before insertion.
- Expose one default shortcut and one secondary hands-free shortcut during onboarding. Advanced multi-binding and mouse-button support can wait.
- Give cancel its own reliable path. Cancel should never be interpreted as "finish and insert."

Apple constraints:

- AppKit can monitor keyboard events systemwide, but key events through a global `NSEvent` monitor require Accessibility trust and are observation-only. [Apple's global event monitor documentation](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents%28matching%3Ahandler%3A%29)
- `AXIsProcessTrustedWithOptions` reports whether the process is a trusted Accessibility client and can ask macOS to show the permission prompt. Prompting is asynchronous, so Omil still needs to observe permission state and guide the user back from System Settings. [Apple's Accessibility trust API](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)
- The Mac App Store requires App Sandbox. Apple lists assistive use of Accessibility APIs and arbitrary cross-app automation among activities incompatible with the sandbox. The full insertion product should therefore remain a direct, signed and notarized Mac distribution unless its delivery mechanism changes. [Apple's App Sandbox guidance](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)
- If Omil ever ships a sandboxed client, it needs the outgoing-network entitlement even when the Bun server runs on the same Mac. [Apple's network client entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client)
- Prefer HTTPS for remote and local-network servers. If local HTTP is intentional, use the narrow `NSAllowsLocalNetworking` App Transport Security setting instead of disabling transport security globally. [Apple's local networking setting](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)

### Floating feedback

Verified:

- The Flow Bar is a small floating control that represents resting, recording, and processing. It also exposes microphone and language selection, Paste Last Transcript, and reminder controls from its context menu. [Move and dock the Flow Bar on desktop](https://docs.wisprflow.ai/articles/1790396454-move-and-dock-the-flow-bar-on-desktop)
- Moving white bars confirm that audio is being captured when sound effects are disabled. Hands-free mode adds explicit stop and cancel controls. [Starting your first dictation](https://docs.wisprflow.ai/articles/6409258247-starting-your-first-dictation) and [Use Flow hands-free](https://docs.wisprflow.ai/articles/6391241694-use-flow-hands-free)
- Interactive portions accept clicks while transparent or empty portions pass clicks to the app below. A setting can keep the bar out of screenshots and screen shares. [Move and dock the Flow Bar on desktop](https://docs.wisprflow.ai/articles/1790396454-move-and-dock-the-flow-bar-on-desktop)
- Wispr's current pages conflict on the new-install default. The dedicated Flow Bar page says it is hidden by default, while the hands-free page says it is shown by default. We should not infer the intended default from these sources. [Move and dock the Flow Bar on desktop](https://docs.wisprflow.ai/articles/1790396454-move-and-dock-the-flow-bar-on-desktop) and [Use Flow hands-free](https://docs.wisprflow.ai/articles/6391241694-use-flow-hands-free)

Omil direction:

- Use one compact pill with explicit states: ready, recording, processing, inserted, needs attention.
- Recording should prioritize an input level or waveform and elapsed time. Processing should use a distinct motion and label. Do not display a fake live transcript.
- In hands-free mode, show stop and cancel. In hold-to-talk mode, releasing the key is enough, and the pill can stay visually quieter.
- Make the idle pill optional. Always show it while recording, processing, or reporting an error.
- Keep it nonactivating so it does not steal the target field's focus. Use a small AppKit `NSPanel` host around the SwiftUI content. Apple says floating panels are appropriate when they are small, pointer-oriented, and need to remain visible while the user works elsewhere. [Apple's floating panel guidance](https://developer.apple.com/documentation/appkit/nspanel/isfloatingpanel)
- Use window collection behavior deliberately so the pill can join the active Space and coexist with full-screen apps. [Apple's window collection behavior documentation](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct)

### Final transcript and automatic insertion

Verified:

- Desktop Flow waits until the user stops, then inserts a finished transcript. It does not display words live as they are spoken. [What is Wispr Flow?](https://docs.wisprflow.ai/articles/2772472373-what-is-flow)
- The user is expected to keep the intended field focused through processing. Flow temporarily uses the clipboard for insertion and then restores supported prior clipboard contents. If insertion fails, it places the transcript on the clipboard and shows a manual paste path. [Starting your first dictation](https://docs.wisprflow.ai/articles/6409258247-starting-your-first-dictation) and [Fix text not pasting after dictation](https://docs.wisprflow.ai/articles/7971211038-Fix-text-not-pasting-after-dictation)
- Mac recovery actions include Paste Last Transcript and Copy Last Transcript. The current shortcut page lists `Cmd+Ctrl+V` and `Cmd+Ctrl+C` as defaults, although some terminal guidance says Mac may have no default in some versions. The app should display the user's actual binding. [Supported and unsupported keyboard hotkey shortcuts](https://docs.wisprflow.ai/articles/2612050838-Supported-&-Unsupported-Keyboard-Hotkey-Shortcuts) and [Using Flow with terminal applications](https://docs.wisprflow.ai/articles/6478598909-using-flow-with-linux-wsl-and-terminal-applications)
- Standard `Cmd+Z` can immediately revert pasted Auto Cleanup output. [Auto Cleanup](https://docs.wisprflow.ai/articles/4283510616-Auto-Cleanup:-control-how-much-Flow-edits-your-dictation)

Omil direction:

- Model transcription, cleanup, and insertion as separate steps. A successful transcript with a failed insertion is not a failed transcription.
- Insert only after the Effect and Bun server returns a finished result and the Mac app revalidates the destination.
- If the focused destination changed, preserve the result and offer Copy and Insert here. Do not paste into whichever field happens to be active.
- Maintain a last-result recovery action outside the transient pill.
- If Omil temporarily owns the pasteboard, record its change count and restore prior contents only while Omil still owns it. Apple documents `changeCount` specifically for checking whether pasteboard ownership changed. [Apple's `NSPasteboard.changeCount`](https://developer.apple.com/documentation/appkit/nspasteboard/changecount)

## Cleanup, corrections, and control

### Spoken corrections and formatting

Verified:

- Backtrack resolves corrections inside one dictation. It recognizes explicit cues such as "actually," "scratch that," and "never mind," and can also use a natural restatement without a trigger phrase. Wispr says it uses the full dictation as context. [Smart Formatting and Backtrack](https://docs.wisprflow.ai/articles/5373093536-How-do-I-use-Smart-Formatting-&-Backtrack)
- Clear non-correction uses of words such as "actually" should remain. Flow's documented example preserves "I actually enjoyed the movie." [Smart Formatting and Backtrack](https://docs.wisprflow.ai/articles/5373093536-How-do-I-use-Smart-Formatting-&-Backtrack)
- Smart Formatting handles punctuation, capitalization, filler cleanup, line and paragraph commands, and list formation. It does not claim to fix misheard words. [Smart Formatting and Backtrack](https://docs.wisprflow.ai/articles/5373093536-How-do-I-use-Smart-Formatting-&-Backtrack)
- Auto Cleanup has None, Light, and Medium levels. None preserves raw wording without formatting or corrections. Light removes fillers and fixes grammar. Medium may reword for clarity and concision. Light is the default. [Auto Cleanup](https://docs.wisprflow.ai/articles/4283510616-Auto-Cleanup:-control-how-much-Flow-edits-your-dictation)
- Desktop history can undo and redo an AI edit for one transcript, exposing the pre-cleanup result again. [Smart Formatting and Backtrack](https://docs.wisprflow.ai/articles/5373093536-How-do-I-use-Smart-Formatting-&-Backtrack)

Omil direction:

- Keep three concepts separate in the UI: Verbatim, Clean, and Polish. Verbatim should preserve the server transcript. Clean should resolve high-confidence fillers, repetitions, formatting, and spoken repairs. Polish may rephrase and must be opt-in.
- Keep the raw transcription and cleaned result together. The user should be able to compare them and restore raw text.
- Backtrack needs the entire utterance and correction history. Do not clean finalized chunks independently and discard the earlier alternatives.
- Treat correction cues as evidence, not commands. Preserve ordinary uses of "actually," quoted speech, negation, and repeated phrases when the correction scope is unclear.
- Do not describe cleanup as correcting recognition errors. The personal dictionary handles recurring spellings; cleanup handles structure and intentional repairs.

### Personal dictionary and learned corrections

Verified:

- The dictionary stores names, technical terms, and jargon. A correction entry maps a recurring wrong spelling to the desired spelling, capitalization, and punctuation. Desktop matching is whole-word and case-insensitive, prefers longer overlapping phrases, and emits the saved form literally. [Teach Flow your words with the dictionary](https://docs.wisprflow.ai/articles/4052411709-Teach-Flow-your-words-with-the-dictionary)
- Current dictation uses the 200 most recently modified personal and shared entries. Dictionary entries can be searched, edited, and deleted on desktop. [Teach Flow your words with the dictionary](https://docs.wisprflow.ai/articles/4052411709-Teach-Flow-your-words-with-the-dictionary)
- Wispr says its optional Auto-add to Dictionary setting monitors the field where Flow inserted text. If the user changes a word's spelling, Flow can add that correction automatically. [Wispr data controls](https://wisprflow.ai/data-controls)
- The help center warns that deleting a desktop dictionary entry is permanent and auto-learning will not add it again. [Teach Flow your words with the dictionary](https://docs.wisprflow.ai/articles/4052411709-Teach-Flow-your-words-with-the-dictionary)

Omil direction:

- Ship manual terms and explicit wrong-to-right replacements first.
- Apply exact replacements deterministically after transcription and before broader rewriting. Longest whole-phrase match should win.
- Show the actual replacement rule. Dictionary membership alone must not authorize the cleanup model to invent the term elsewhere.
- Treat edit monitoring as a separate, opt-in feature. Reading a field after insertion is a privacy-sensitive Accessibility operation. Prefer "Add correction?" suggestions over silently saving every observed edit.

### Snippets and spoken commands

Verified:

- A snippet pairs a spoken trigger with static saved text. Saying the trigger alone or inside a sentence expands it. On desktop, the longest matching trigger wins, and a personal snippet wins over a shared snippet with identical wording. [Create and use snippets](https://docs.wisprflow.ai/articles/5784437944-create-and-use-snippets)
- Desktop snippets can contain bold, italic, lists, and links. Rich formatting survives only when the entire dictation is the trigger, the destination accepts formatted paste, and no later command or automatic action changes the text. Otherwise Flow inserts plain text. [Create and use snippets](https://docs.wisprflow.ai/articles/5784437944-create-and-use-snippets)
- Command Mode is a separate paid, experimental interaction. The user holds a distinct shortcut, says an instruction, and releases it to act on existing or selected text. Failed editing commands can do nothing without an error. [How to use Command Mode](https://docs.wisprflow.ai/articles/4816967992-how-to-use-command-mode)
- Spoken formatting commands such as "new line," "new paragraph," punctuation names, and naturally enumerated lists remain part of ordinary dictation. [Smart Formatting and Backtrack](https://docs.wisprflow.ai/articles/5373093536-How-do-I-use-Smart-Formatting-&-Backtrack)

Omil direction:

- Snippets are worth implementing before a general command mode. Their trigger and output are inspectable, deterministic, and easy to undo.
- Resolve dictionary and snippet conflicts in the editor. Use longest-trigger matching and show why a trigger was rejected.
- Keep general voice commands on a distinct shortcut and visual state. A command should never be mistaken for text to insert.
- Require a visible preview or a safe no-op for destructive commands. Flow's documented silent command failures are not behavior to copy.

## Styles and app context

### Writing styles

Verified:

- Flow assigns a style per app category: Personal messages, Work messages, Email, and Other. Current style choices are Formal, Casual, Very Casual for personal messages only, and Excited for every category except personal. [How to set up Flow Styles](https://docs.wisprflow.ai/articles/2368263928-how-to-setup-flow-styles)
- Flow detects both native apps and supported websites, maps them to a category, and applies the corresponding style to new dictations. Users can assign more apps themselves. [How to set up Flow Styles](https://docs.wisprflow.ai/articles/2368263928-how-to-setup-flow-styles)
- Styles change capitalization, punctuation, and exclamation behavior. Wispr says they are optimized for English. [How to set up Flow Styles](https://docs.wisprflow.ai/articles/2368263928-how-to-setup-flow-styles)

Omil direction:

- Start with useful behavior names, not personality names: Faithful, Concise, Casual, and Formal.
- Let the user choose a default and optional per-app override. Show the active app and style in history so surprising output can be explained.
- Keep style downstream of faithful cleanup. Backtrack, dictionary replacements, and explicit formatting commands should resolve before tone changes.

### Context awareness

Verified:

- On Mac, Flow's Context Awareness can use the active app, text before and after the cursor, selected text, on-screen text, code symbols and file names, an in-app user identifier, apps in the current session, a screenshot, and conversation content and roles. It sends context with each dictation unless Privacy Mode is on. [Context Awareness](https://docs.wisprflow.ai/articles/4678293671-Context-Awareness)
- Flow uses this context for names, app classification, style, capitalization, punctuation, spacing, and code terminology. Browser sites can be classified separately from the browser itself. [Context Awareness](https://docs.wisprflow.ai/articles/4678293671-Context-Awareness)
- Flow excludes standard macOS password fields, sensitive and numeric-only fields, browser URL bars, recognized banking and financial apps, and Flow itself. Wispr warns that custom or web password fields may still look like ordinary text fields. [Context Awareness](https://docs.wisprflow.ai/articles/4678293671-Context-Awareness)
- Accessibility is required for Mac Context Awareness. Screen Recording is optional for basic dictation and may be requested only when a screen-reading feature is used. [Supported devices and system requirements](https://docs.wisprflow.ai/articles/1036674442-Supported-devices-and-system-requirements)

Omil direction:

- Do not collapse this into one opaque "context" toggle. Separate active app identity, nearby field text, and screen capture.
- Default to active app identity only. Add a narrow nearby-text window after explicit consent. Leave screenshots and conversation capture out of the first version.
- Use an allowlist for app-specific context, plus permanent exclusions for password managers, financial apps, secure fields, and Omil itself.
- Show what category and context sources were used on each history item. Never send unrelated window content to the Bun server.
- Accessibility attributes are not universally available. Apple's API can return unsupported, no-value, invalid-element, or messaging errors, so missing context must degrade to context-free transcription instead of blocking dictation. [Apple's `AXUIElementCopyAttributeValue`](https://developer.apple.com/documentation/applicationservices/1462085-axuielementcopyattributevalue)

## History, privacy, and permissions

### History and recovery

Verified:

- Flow's desktop Hub groups transcript history by date and supports search, copy, feedback, and row actions. History stays on the device where the dictation happened and does not sync as text across devices. [Navigating the Wispr Flow app](https://docs.wisprflow.ai/articles/5096240724-navigating-the-wispr-flow-app-desktop-ios-and-android) and [Fix text not pasting after dictation](https://docs.wisprflow.ai/articles/7971211038-Fix-text-not-pasting-after-dictation)
- A transcript can be deleted from Recent Activity. Deletion has no restore path. Desktop local retention can be normal, automatic after 24 hours, or disabled entirely. [Delete transcripts and history](https://docs.wisprflow.ai/articles/4465314211-Delete-transcripts-and-history-in-Wispr-Flow)
- Desktop can retry a failed transcript from saved audio. Audio playback and extraction expire after 14 days, while transcript text may remain. A no-storage policy disables this recovery. [Retry and recover a failed transcription](https://docs.wisprflow.ai/articles/2503460374-retry-failed-transcriptions)
- Feedback is transcript-specific. Desktop History has a flag action that opens a report intended to improve the model, which is distinct from support. [Retry and recover a failed transcription](https://docs.wisprflow.ai/articles/2503460374-retry-failed-transcriptions)

Omil direction:

- Every session row should store status, raw transcript, cleaned transcript, final inserted text, target app, active mode, and recoverable audio status.
- Keep text history local by default. Make raw audio retention off by default, with a clear time limit when enabled.
- Expose Copy, Insert here, Retry transcription, Retry cleanup, Restore raw, and Delete. Each action should say which stage it repeats.
- Feedback should let the user mark transcription, cleanup, or insertion as the problem. These failures have different owners and need different diagnostics.

### Onboarding and permission repair

Verified:

- Flow requests Microphone and Accessibility during Mac onboarding. Granting one permission reveals the next card. Screen Recording is not required for basic dictation. [How to install Wispr Flow on Mac](https://docs.wisprflow.ai/articles/7682075140-how-to-install-wispr-flow-on-mac) and [Re-verify permissions after updating](https://docs.wisprflow.ai/articles/5510622673-re-verify-wispr-flow-permissions-after-updating)
- Setup tests the microphone with live level bars and lets the user switch inputs. It then asks for push-to-talk or hands-free shortcut selection, dictation languages, a practice dictation, and data preferences. Interrupted setup resumes from saved progress. [Set up Wispr Flow for your first dictation](https://docs.wisprflow.ai/articles/3152211871)
- If a user denied a permission earlier, Flow opens the matching System Settings pane and checks the state again when the app returns to the foreground. Missing-permission notifications carry actions such as Grant Permission and Open Settings. [Re-verify permissions after updating](https://docs.wisprflow.ai/articles/5510622673-re-verify-wispr-flow-permissions-after-updating)
- Flow's first-dictation guidance asks the user to test a short sentence in a note or message. [Starting your first dictation](https://docs.wisprflow.ai/articles/6409258247-starting-your-first-dictation)

Omil direction:

- Use a staged onboarding checklist: server ready, microphone, Accessibility, shortcut practice, first successful insertion.
- Explain each permission at the moment it is needed. Microphone captures speech. Accessibility observes the global shortcut, identifies a destination, and inserts text. Context permissions come later and remain optional.
- Each card should have four states: not requested, waiting in System Settings, granted, and needs repair.
- End with a real practice field and then a guided insertion into Notes. A permissions screen without a successful round trip is not complete onboarding.

Apple constraints:

- macOS requires explicit microphone permission. The app needs `NSMicrophoneUsageDescription`, and a sandboxed build also needs the audio input entitlement. Apple recommends checking authorization before creating the capture session. [Apple's media capture authorization guidance](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media)
- The system remembers the user's microphone choice. After denial, Omil should open Settings and recheck rather than pretending it can show the prompt again. [Apple's `AVCaptureDevice.requestAccess`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/requestaccess%28for%3Acompletionhandler%3A%29)
- Omil does not need to request Apple's `SFSpeechRecognizer` permission while Swift only records audio and the Effect and Bun server performs recognition. Apple requires `NSSpeechRecognitionUsageDescription` when an app uses APIs that send data to Apple's speech recognition servers. [Apple's speech recognition permission guide](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition)

### Privacy choices

Verified:

- Wispr says transcription always occurs in the cloud. Model-improvement permission, cloud storage, local history, and Context Awareness are separate controls. Turning off one does not imply the others are off. [Wispr data controls](https://wisprflow.ai/data-controls) and [Manage data sharing, cloud storage and local history](https://docs.wisprflow.ai/articles/9609615338-Private-Cloud-Sync-and-Data-Sharing-preferences-in-Wispr-Flow)
- Local deletion does not necessarily delete copies already uploaded to Wispr. [Delete transcripts and history](https://docs.wisprflow.ai/articles/4465314211-Delete-transcripts-and-history-in-Wispr-Flow)

Omil direction:

- Say exactly where the Effect and Bun server runs and what model services it calls. "Local server" is not enough if that server forwards audio or text elsewhere.
- Show connection and processing status in plain language: On this Mac, Local network, or Remote server.
- Keep audio, transcript, context, and diagnostic-log retention as separate settings.
- Never turn context collection or correction monitoring on as a side effect of granting Accessibility.

## Feedback states and failure recovery

Flow's recovery design is as important as its successful path.

Verified:

- Recording feedback uses a start sound or moving white bars. The Flow Bar then distinguishes recording from processing. [Starting your first dictation](https://docs.wisprflow.ai/articles/6409258247-starting-your-first-dictation) and [Move and dock the Flow Bar on desktop](https://docs.wisprflow.ai/articles/1790396454-move-and-dock-the-flow-bar-on-desktop)
- Microphone failures offer direct actions such as Select microphone, Troubleshoot, Grant Permission, or Insert for audio captured before a disconnect. [Why isn't Flow recording my voice?](https://docs.wisprflow.ai/articles/2841416128-why-isn-t-flow-recording-my-voice)
- Flow separates retrying transcription from pasting existing text. A desktop retry may recover saved audio, while Paste Last Transcript handles a result that exists but did not reach its field. [Retry and recover a failed transcription](https://docs.wisprflow.ai/articles/2503460374-retry-failed-transcriptions)
- If offline, desktop Flow can still record, warn the user, save audio, and offer retry when connectivity returns. [Use Flow hands-free](https://docs.wisprflow.ai/articles/6391241694-use-flow-hands-free)

Recommended Omil state model:

```text
ready
  -> recording
  -> stopping
  -> transcribing
  -> cleaning
  -> validating destination
  -> inserting
  -> inserted
```

Failure branches should keep the last safe artifact:

| Failure | Preserve | User action |
| --- | --- | --- |
| Microphone unavailable before capture | Nothing | Choose microphone, grant access, retry |
| Microphone disconnects after capture starts | Captured audio | Finish with captured audio or discard |
| Bun server unreachable | Audio | Retry connection, copy audio path, delete |
| Transcription fails | Audio and server error | Retry transcription |
| Cleanup fails | Raw transcript | Retry cleanup, copy raw, delete |
| Target changes during processing | Final text | Insert here or copy |
| Automatic insertion fails | Final text and intended target metadata | Retry insertion or copy |
| User cancels | Nothing inserted | Dismiss, with recovery only if retention policy permits it |

This table is an Omil proposal. Wispr's exact server pipeline is not documented. The split matches Omil's Effect and Bun boundary and prevents a paste failure from being reported as a transcription failure.

## Build order for Omil

### First usable release

- Global hold-to-talk and separate hands-free toggle.
- Compact state pill with audio feedback, processing, success, and actionable error states.
- Finished transcript only after release.
- Automatic insertion with destination revalidation.
- Last-result copy and paste recovery.
- Local history with raw and cleaned text.
- Microphone, Accessibility, server-readiness, and first-insertion onboarding.
- Explicit transcription, cleanup, and insertion failure states.

### Quality and personalization

- Backtrack across the full session.
- Spoken punctuation, new line, new paragraph, and lists.
- Verbatim, Clean, and Polish modes with raw restoration.
- Personal terms and exact correction mappings.
- Static voice snippets with longest-trigger matching.
- Per-app styles based on app identity.

### Later, after privacy and reliability tests

- Nearby-text context on a per-app allowlist.
- Opt-in suggestions derived from post-insertion edits.
- General Command Mode with preview, undo, and clear no-op feedback.
- Rich-text snippets after plain-text insertion is reliable across target apps.
- Live draft transcription only if user testing shows that it helps more than it distracts.

## Claims Omil should not make

- Do not call a live word-by-word transcript "Wispr-like" on Mac. Wispr's current desktop docs explicitly describe completed insertion after the user stops.
- Do not say cleanup fixes recognition errors. Wispr's own Smart Formatting page says it does not correct misheard words.
- Do not say the product is offline merely because the Mac client talks to a Bun server. Verify every model and network hop.
- Do not describe context as only "nearby text." Flow's current context can include screenshots, app history, and conversation content.
- Do not imply deleting local history deletes remote data.
- Do not request Screen Recording for basic dictation. Add it only when a visible, optional context feature needs it.
- Do not silently paste after the target changes. Preserve the result and ask the user where it belongs.
