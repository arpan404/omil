import { describe, expect, test } from "bun:test"
import { preprocessWav } from "../src/AudioPreprocessor"
import { AUDIO_PROFILES, parseAudioSensitivity } from "../src/AudioSensitivity"

const sampleRate = 16_000

const makeWav = (samples: Int16Array, rate = sampleRate): Buffer => {
  const wav = Buffer.alloc(44 + samples.length * 2)
  wav.write("RIFF", 0)
  wav.writeUInt32LE(wav.length - 8, 4)
  wav.write("WAVEfmt ", 8)
  wav.writeUInt32LE(16, 16)
  wav.writeUInt16LE(1, 20)
  wav.writeUInt16LE(1, 22)
  wav.writeUInt32LE(rate, 24)
  wav.writeUInt32LE(rate * 2, 28)
  wav.writeUInt16LE(2, 32)
  wav.writeUInt16LE(16, 34)
  wav.write("data", 36)
  wav.writeUInt32LE(samples.length * 2, 40)
  samples.forEach((sample, index) => wav.writeInt16LE(sample, 44 + index * 2))
  return wav
}

const peak = (wav: Buffer): number => {
  let value = 0
  for (let offset = 44; offset < wav.length; offset += 2) {
    value = Math.max(value, Math.abs(wav.readInt16LE(offset)))
  }
  return value
}

const rms = (wav: Buffer): number => {
  let squares = 0
  const count = (wav.length - 44) / 2
  for (let offset = 44; offset < wav.length; offset += 2) {
    const sample = wav.readInt16LE(offset)
    squares += sample * sample
  }
  return Math.sqrt(squares / count)
}

describe("server audio preprocessing", () => {
  test("accepts per-client sensitivity and preserves the balanced default", () => {
    expect(parseAudioSensitivity(null)).toBe("balanced")
    expect(parseAudioSensitivity("distant")).toBe("distant")
    expect(parseAudioSensitivity("strict")).toBe("strict")
    expect(parseAudioSensitivity("invalid")).toBeNull()
    expect(AUDIO_PROFILES.distant.vadThreshold).toBeLessThan(AUDIO_PROFILES.balanced.vadThreshold)
    expect(AUDIO_PROFILES.strict.vadThreshold).toBeGreaterThan(AUDIO_PROFILES.balanced.vadThreshold)
    expect(AUDIO_PROFILES.distant.minSilenceMs).toBeGreaterThan(AUDIO_PROFILES.balanced.minSilenceMs)
  })

  test("marks a silent upload as speech-free before Whisper can invent words", () => {
    const result = preprocessWav(makeWav(new Int16Array(sampleRate)))
    expect(result.silent).toBe(true)
  })

  test("removes DC offset and low rumble", () => {
    const samples = Int16Array.from({ length: sampleRate * 2 }, (_, i) =>
      Math.round(2_500 + 1_000 * Math.sin(2 * Math.PI * 40 * i / sampleRate)))
    const input = makeWav(samples)
    const result = preprocessWav(input)
    expect(result.silent).toBe(false)
    expect(rms(result.wav)).toBeLessThan(rms(input) * 0.45)
  })

  test("lifts quiet speech-shaped audio without clipping", () => {
    const samples = Int16Array.from({ length: sampleRate * 2 }, (_, i) => {
      const time = i / sampleRate
      if (time < 0.3 || time > 1.7) return 0
      return Math.round(800 * Math.sin(2 * Math.PI * 220 * time)
        * (0.7 + 0.3 * Math.sin(2 * Math.PI * 3 * time)))
    })
    const input = makeWav(samples)
    const result = preprocessWav(input)
    expect(result.silent).toBe(false)
    expect(peak(result.wav)).toBeGreaterThan(peak(input))
    expect(peak(result.wav)).toBeLessThan(32_768)
  })

  test("does not boost steady background noise", () => {
    let seed = 5
    const samples = Int16Array.from({ length: sampleRate * 2 }, () => {
      seed = (seed * 1_664_525 + 1_013_904_223) >>> 0
      return (seed % 361) - 180
    })
    const input = makeWav(samples)
    const result = preprocessWav(input)
    expect(peak(result.wav)).toBeLessThanOrEqual(peak(input) * 1.2)
    expect(peak(preprocessWav(input, "distant").wav)).toBeLessThanOrEqual(peak(input) * 1.2)
  })

  test("does not boost louder steady room noise", () => {
    let seed = 17
    const samples = Int16Array.from({ length: sampleRate * 2 }, () => {
      seed = (seed * 1_664_525 + 1_013_904_223) >>> 0
      return (seed % 1_601) - 800
    })
    const input = makeWav(samples)
    for (const sensitivity of ["strict", "balanced", "distant"] as const) {
      expect(peak(preprocessWav(input, sensitivity).wav)).toBeLessThanOrEqual(peak(input) * 1.2)
    }
  })

  test("distant sensitivity lifts very quiet speech-shaped audio", () => {
    const samples = Int16Array.from({ length: sampleRate * 2 }, (_, i) => {
      const time = i / sampleRate
      return time < 0.3 || time > 1.7 ? 0 : Math.round(100 * Math.sin(2 * Math.PI * 220 * time))
    })
    const input = makeWav(samples)
    const balanced = preprocessWav(input, "balanced")
    const distant = preprocessWav(input, "distant")
    expect(balanced.silent).toBe(false)
    expect(distant.silent).toBe(false)
    expect(peak(distant.wav)).toBeGreaterThan(peak(balanced.wav) * 3)
    expect(peak(distant.wav)).toBeLessThan(32_768)
  })

  test("leaves an unfamiliar WAV format for whisper-cli to handle", () => {
    const input = makeWav(new Int16Array(sampleRate), 48_000)
    const result = preprocessWav(input)
    expect(result.wav).toBe(input)
    expect(result.silent).toBe(false)
  })
})
