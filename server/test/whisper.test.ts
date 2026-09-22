import { describe, expect, test } from "bun:test"
import { normalizeWhisperLanguage, parseWhisperJson } from "../src/Whisper"

describe("whisper adapter", () => {
  test("normalizes locale tags to whisper language codes", () => {
    expect(normalizeWhisperLanguage("en-US")).toBe("en")
    expect(normalizeWhisperLanguage("pt_BR")).toBe("pt")
    expect(normalizeWhisperLanguage("auto")).toBe("auto")
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
})
