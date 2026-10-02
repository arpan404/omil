# Omil launch video

A 54-second film at 1920×1080 and 30 fps, built with [Remotion](https://remotion.dev).

```sh
bun install
bun run assets       # downloads music and sound effects, prepares the voice line
bun run studio       # live preview
bun run render       # writes out/omil-launch.mp4
bun run site-media   # renders the website's images into ../site/public/media
```

## Story

1. The problem: "You think faster than you type."
2. The answer: Omil.
3. How it works: a close-up of the pill while a line is spoken, then the camera pulls back and the clean text lands in Messages.
4. Cleanup: the same dictation in Omil's window, the Changes diff, Clean and Verbatim.
5. Make it yours: Snippets and Dictionary.
6. iPhone and iPad: pairing with the Mac by QR code, then dictating from the Omil keyboard in Messages and Mail.
7. Privacy: everything stays on the Mac.
8. Download.

## Audio

- Music: "Driving Ambition" by Ahjay Stelino (Mixkit Stock Music Free License). `scripts/music.py` rearranges it bar by bar to fit the scenes.
- Sound effects: key and click sounds from Kenney Interface Sounds (CC0).
- Voice: Qwen3-TTS 1.7B (Apache-2.0) through mlx-audio, cloning the Apache-2.0 `en_man` sample voice from boson-ai/higgs-audio. The take in use is `voice/qwen3-clone-take6.wav`. `scripts/voice.py` regenerates it.

`scripts/align-voice.ts` writes word timings to `src/voice-timing.json`, which drives the captions and the demo. To use a different take or a real recording, copy it in and run `bun run assets`.

## Design

The film uses the app's light theme: the same colors (`Sources/OmilDesign/Palette.swift`), the same pill, and the app's spring for UI motion. The Changes tab shows the real diff output.

Type is macOS SF Pro and SF Mono. `bun run assets` copies the fonts from the system into `public/fonts/`, which git ignores. Apple's license allows them in UI mockups but not redistribution.

The Remotion agent skills are installed in `.claude/skills/`.
