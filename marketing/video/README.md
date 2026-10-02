# Omil launch video

54s (22.5 bars at ~99.8 BPM), 1920×1080, 30 fps, built with [Remotion](https://remotion.dev). The official Remotion agent
skills are installed in `.claude/skills/`.

```sh
bun install
bun run assets    # downloads music + SFX, renders the voice line with Kokoro
bun run studio    # live preview
bun run render    # -> out/omil-launch.mp4
```

## Audio

- Music: "Driving Ambition" by Ahjay Stelino (Mixkit Stock Music Free License). Picked from 90+
  ambient/film-score tracks for a clear major key (C major), a calm tempo and a steady build.
  `scripts/music.py` re-arranges it bar by bar: the gentle intro under the problem, title and dictation,
  the lift on "make it yours", the peak under the privacy line, and the track's own ending under the logo.
- SFX: only soft key/click sounds for the real interactions (Kenney Interface Sounds, CC0).
- Voice: Qwen3-TTS 1.7B (Apache-2.0) via mlx-audio, cloning the Apache-2.0 `en_man` sample voice
  from boson-ai/higgs-audio. The chosen take is `voice/qwen3-clone-take6.wav`; `scripts/voice.py`
  regenerates it. It won a shoot-out against Fish S2 Pro, Higgs Audio v2/v3, VoxCPM2, Dia, Voxtral
  and Kokoro on UTMOS naturalness, pitch range and whisper accuracy. `scripts/align-voice.ts`
  word-aligns it into `src/voice-timing.json`, which drives the captions and demo cues, so a
  different take (or a real recording) just needs copying in and `bun run assets`.

## Story

1. The problem: "You think faster than you type."
2. The answer: Omil.
3. How it works: one continuous take. A close-up on the real pill while the line is spoken, the camera
   pulls back to a Mac, release, and clean text lands in Messages.
4. Why it's smart: the same dictation in Omil's window, the git-style Changes diff (GitDiffView), Clean vs Verbatim.
5. Make it yours: Snippets (⌘3) and Dictionary (⌘4), on the music's lift.
6. Everywhere: pair iPhone and iPad with the Mac by QR code (the Mac does the transcription, no
   subscription). In Messages on iPhone, tap the mic on the Omil keyboard: Omil opens for a moment,
   already listening ("Go back and keep talking"), "◀ Messages" returns, tap ✓, the text lands and the
   user's own keyboard comes back. On iPad the mic is already ready, so Mail is dictated straight from
   the keyboard.
7. Trust: private by design, on the music's peak.
8. Call to action, on the music's ending.

## Design

Light mode, matching the app: OmilDesign Graphite light (Palette.swift), flat floating controls
with a hairline (liquidGlass() is flat in light mode), the near-black FlowPill, and UI motion on the
app's own spring (OmilMotion.standard). The Changes tab shows DiffUtil.diff's exact output. Type is
macOS SF Pro / SF Mono, loaded from the system files that `bun run assets` copies into
`public/fonts/` (gitignored; Apple's license allows UI mockups, not redistribution). Cursor targets and
camera framing come from the same layout numbers that draw each control.
