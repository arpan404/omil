import { describe, expect, test } from "bun:test"
import {
  normalizeWhisperLanguage, parseWhisperJson, parseWhisperServerJson, serverRequestFields, supportsWhisperLanguage,
} from "../src/Whisper"
import { AUDIO_PROFILES } from "../src/AudioSensitivity"

/** whisper-cli's JSON timestamp for a time in 10 ms units. */
const cliTimestamp = (centiseconds: number): string => {
  const ms = centiseconds * 10
  const pad = (value: number, width = 2) => String(value).padStart(width, "0")
  return `${pad(Math.floor(ms / 3_600_000))}:${pad(Math.floor(ms / 60_000) % 60)}:${pad(Math.floor(ms / 1_000) % 60)},${pad(ms % 1_000, 3)}`
}

describe("whisper adapter", () => {
  test("normalizes locale tags to whisper language codes", () => {
    expect(normalizeWhisperLanguage("en-US")).toBe("en")
    expect(normalizeWhisperLanguage("pt_BR")).toBe("pt")
    expect(normalizeWhisperLanguage("auto")).toBe("auto")
  })

  test("limits distilled Whisper to English without restricting multilingual models", () => {
    expect(supportsWhisperLanguage("whisper-distil-large-v3", "en-US")).toBe(true)
    expect(supportsWhisperLanguage("whisper-distil-large-v3", "fr-FR")).toBe(false)
    expect(supportsWhisperLanguage("whisper-large-v3-turbo-q8", "fr-FR")).toBe(true)
  })

  test("parses comma timestamps from whisper.cpp JSON", () => {
    const transcript = parseWhisperJson(JSON.stringify({
      transcription: [{
        timestamps: { from: "00:00:00,120", to: "00:00:02,840" },
        text: " Make it 42.",
      }],
    }), "whisper-large-v3-turbo")

    expect(transcript.text).toBe("Make it 42.")
    expect(transcript.segments[0]).toEqual({
      start: 0.12,
      end: 2.84,
      text: "Make it 42.",
    })
  })

  test("maps whisper-server verbose_json to the same transcript as whisper-cli JSON", () => {
    // Naive `seconds = start` differs from the CLI value for many of these.
    const times = [0, 1, 7, 12, 99, 284, 1_007, 5_999, 6_000, 6_507, 59_999, 123_456, 360_000, 370_001,
      ...Array.from({ length: 2_000 }, (_, index) => index * 137)]
    for (const t0 of times) {
      const t1 = t0 + 283
      const cli = parseWhisperJson(JSON.stringify({
        transcription: [
          { timestamps: { from: cliTimestamp(t0), to: cliTimestamp(t1) }, text: " Make it 42," },
          { timestamps: { from: cliTimestamp(t1), to: cliTimestamp(t1 + 90) }, text: " sorry 21. " },
        ],
      }), "whisper-large-v3-turbo-q8")
      // The server serializes `t * 0.01` as a double, e.g. 0.07000000000000001.
      const server = parseWhisperServerJson(JSON.stringify({
        task: "transcribe", language: "english", duration: 3.2, text: " Make it 42, sorry 21.",
        segments: [
          { id: 0, text: " Make it 42,", start: t0 * 0.01, end: t1 * 0.01, tokens: [1], words: [], no_speech_prob: 0.01 },
          { id: 1, text: " sorry 21. ", start: t1 * 0.01, end: (t1 + 90) * 0.01 },
        ],
      }), "whisper-large-v3-turbo-q8")
      expect(server).toEqual(cli)
      expect(JSON.stringify(server)).toBe(JSON.stringify(cli))
    }
  })

  test("maps an empty whisper-server result to an empty transcript", () => {
    expect(parseWhisperServerJson(JSON.stringify({ text: "", segments: [] }), "m"))
      .toEqual({ text: "", segments: [], model: "m" })
  })

  test("sends per-request language, beam search, and speech-detection settings", () => {
    const fields = serverRequestFields("fr", AUDIO_PROFILES.distant)
    expect(fields).toMatchObject({
      response_format: "verbose_json",
      language: "fr",
      temperature: "0",
      beam_size: "5",
      best_of: "5",
      token_timestamps: "false",
      vad: "true",
      vad_threshold: String(AUDIO_PROFILES.distant.vadThreshold),
      vad_min_speech_duration_ms: String(AUDIO_PROFILES.distant.minSpeechMs),
      vad_min_silence_duration_ms: String(AUDIO_PROFILES.distant.minSilenceMs),
      vad_speech_pad_ms: String(AUDIO_PROFILES.distant.speechPadMs),
    })
  })
})
