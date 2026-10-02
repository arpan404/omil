# Setup and settings

Omil uses Homebrew to install `whisper.cpp` and `llama.cpp` if they are missing, then downloads the models you selected. Without Homebrew, the Engine screen shows the install link, a command to run yourself, and a retry button.

It asks for three permissions:

- Microphone, to record.
- Accessibility, to type into other apps.
- Input Monitoring, so the shortcut works while Omil is in the background.

The Engine screen is where you pick models. Speech: Whisper small Q8 or large-v3 turbo Q8. Cleanup: Qwen3.5 0.8B, 2B, or 4B at Q4. New installs start with large-v3 turbo Q8 and Qwen3.5 2B.

## Settings worth knowing

- Settings → General → Floating pill: Off, While dictating, or Always. Always keeps a draggable Start control on screen. Right-click the pill to hide it without stopping the recording.
- Speech sensitivity: Balanced is the default. Distant voice keeps quieter speech. Filter more noise ignores more background sound. Mac and iPhone each have their own setting.
- If you start dictation from the Omil window or the menu bar, the text goes to the last field you used in another app. If that field is gone, the text stays in Omil.

## Current limits

- English only.
- Installing the speech tools needs Homebrew and an internet connection. The first run also downloads the model weights.
- The iOS app and keyboard have not been checked on a device: recording, handoff, background behavior, latency, and power use are all untested.
- Speech tests use synthetic audio. No evaluation with human speech has been run.
- No Windows or Android app.

