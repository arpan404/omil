import { describe, expect, test } from "bun:test"
import { mkdtemp, readdir, readFile, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import path from "node:path"
import { preprocessWav } from "../src/AudioPreprocessor"
import { AUDIO_PROFILES, type AudioSensitivity } from "../src/AudioSensitivity"

/** The per-sample Buffer implementation that preprocessWav must reproduce bit for bit. */
function referencePreprocess(wav: Buffer, sensitivity: AudioSensitivity): { wav: Buffer; silent: boolean } {
  const profile = AUDIO_PROFILES[sensitivity]
  if (wav.length < 44 || wav.toString("ascii", 0, 4) !== "RIFF" || wav.toString("ascii", 8, 12) !== "WAVE") {
    return { wav, silent: false }
  }
  let format: { codec: number; channels: number; rate: number; bits: number } | null = null
  let range: { offset: number; bytes: number } | null = null
  for (let offset = 12; offset + 8 <= wav.length;) {
    const size = wav.readUInt32LE(offset + 4)
    const body = offset + 8
    if (body + size > wav.length) return { wav, silent: false }
    const name = wav.toString("ascii", offset, offset + 4)
    if (name === "fmt " && size >= 16) {
      format = { codec: wav.readUInt16LE(body), channels: wav.readUInt16LE(body + 2),
        rate: wav.readUInt32LE(body + 4), bits: wav.readUInt16LE(body + 14) }
    } else if (name === "data") {
      range = { offset: body, bytes: size }
    }
    offset = body + size + (size & 1)
  }
  if (!format || format.codec !== 1 || format.channels !== 1 || format.rate !== 16_000
    || format.bits !== 16 || !range || range.bytes % 2 !== 0) return { wav, silent: false }
  if (range.bytes > 16_000 * 2 * 600) return { wav, silent: false }
  const count = range.bytes / 2
  if (count === 0) return { wav, silent: true }
  const frameLevels: number[] = []
  const alpha = 1 / (1 + 2 * Math.PI * 80 / 16_000)
  let previousInput = 0, previousOutput = 0, frameSquares = 0, frameCount = 0, inputPeak = 0, filteredPeak = 0
  for (let index = 0; index < count; index++) {
    const sample = wav.readInt16LE(range.offset + index * 2)
    inputPeak = Math.max(inputPeak, Math.abs(sample))
    const input = sample / 32_768
    const filtered = alpha * (previousOutput + input - previousInput)
    previousInput = input
    previousOutput = filtered
    filteredPeak = Math.max(filteredPeak, Math.abs(filtered))
    frameSquares += filtered * filtered
    frameCount++
    if (frameCount === 320 || index === count - 1) {
      frameLevels.push(Math.sqrt(frameSquares / frameCount))
      frameSquares = 0
      frameCount = 0
    }
  }
  if (inputPeak <= profile.silencePeak) return { wav, silent: true }
  const sorted = frameLevels.sort((a, b) => a - b)
  const low = sorted[Math.floor((sorted.length - 1) * 0.2)] ?? 0
  const high = sorted[Math.floor((sorted.length - 1) * 0.9)] ?? 0
  const hasDynamics = high >= profile.minimumFrameRms
    && (high >= low * profile.dynamicRatio || high - low >= profile.minLevelChange)
  let gain = Math.min(1, 0.95 / filteredPeak)
  if (hasDynamics && filteredPeak > 0) {
    gain = Math.min(profile.maxGain, Math.max(1, 0.08 / high), 0.95 / filteredPeak)
  }
  const result = Buffer.from(wav)
  previousInput = 0
  previousOutput = 0
  for (let index = 0; index < count; index++) {
    const offset = range.offset + index * 2
    const input = wav.readInt16LE(offset) / 32_768
    const filtered = alpha * (previousOutput + input - previousInput)
    previousInput = input
    previousOutput = filtered
    result.writeInt16LE(Math.max(-32_768, Math.min(32_767, Math.round(filtered * gain * 32_768))), offset)
  }
  return { wav: result, silent: false }
}

const wavWithChunks = (samples: Int16Array, extraChunk = false): Buffer => {
  const extra = extraChunk ? Buffer.concat([Buffer.from("LIST"), Buffer.from([3, 0, 0, 0]), Buffer.from("abc\0")]) : Buffer.alloc(0)
  const header = Buffer.alloc(36)
  header.write("RIFF", 0)
  header.write("WAVEfmt ", 8)
  header.writeUInt32LE(16, 16)
  header.writeUInt16LE(1, 20)
  header.writeUInt16LE(1, 22)
  header.writeUInt32LE(16_000, 24)
  header.writeUInt32LE(32_000, 28)
  header.writeUInt16LE(2, 32)
  header.writeUInt16LE(16, 34)
  const dataHeader = Buffer.alloc(8)
  dataHeader.write("data", 0)
  dataHeader.writeUInt32LE(samples.length * 2, 4)
  const data = Buffer.alloc(samples.length * 2)
  samples.forEach((sample, index) => data.writeInt16LE(sample, index * 2))
  const trailer = Buffer.from("id3 \u0002\u0000\u0000\u0000xy", "latin1")
  const wav = Buffer.concat([header, extra, dataHeader, data, trailer])
  wav.writeUInt32LE(wav.length - 8, 4)
  return wav
}

const synthetic = (): Array<[string, Buffer]> => {
  let seed = 11
  const noise = () => {
    seed = (seed * 1_664_525 + 1_013_904_223) >>> 0
    return (seed % 2_001) - 1_000
  }
  const speech = Int16Array.from({ length: 16_000 * 3 }, (_, i) => {
    const time = i / 16_000
    const envelope = time > 0.4 && time < 2.4 ? 0.6 + 0.4 * Math.sin(2 * Math.PI * 4 * time) : 0.02
    return Math.round(3_000 * envelope * Math.sin(2 * Math.PI * 180 * time) + noise() * 0.2)
  })
  const loud = Int16Array.from({ length: 16_000 }, (_, i) =>
    Math.max(-32_768, Math.min(32_767, Math.round(40_000 * Math.sin(2 * Math.PI * 300 * i / 16_000)))))
  return [["speech", wavWithChunks(speech)], ["speech+chunks", wavWithChunks(speech, true)],
    ["clipping", wavWithChunks(loud)], ["noise", wavWithChunks(Int16Array.from({ length: 16_000 }, noise))]]
}

const fixtureDir = path.join(import.meta.dir, "../../Tests/OmilCoreTests/Fixtures/audio-synth")
const afconvert = Bun.which("afconvert")

const fixtures = async (): Promise<Array<[string, Buffer]>> => {
  if (!afconvert) return []
  const names = (await readdir(fixtureDir).catch(() => [] as string[])).filter((name) => name.endsWith(".aiff"))
  const dir = await mkdtemp(path.join(tmpdir(), "omil-fixtures-"))
  try {
    const out: Array<[string, Buffer]> = []
    for (const name of names) {
      const wav = path.join(dir, name.replace(/\.aiff$/, ".wav"))
      const convert = Bun.spawnSync([afconvert, "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", path.join(fixtureDir, name), wav])
      if (convert.exitCode === 0) out.push([name, await readFile(wav)])
    }
    return out
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
}

describe("preprocessWav equivalence", () => {
  test("typed-array implementation is bit-identical to the per-sample reference", async () => {
    const inputs = [...synthetic(), ...await fixtures()]
    expect(inputs.length).toBeGreaterThanOrEqual(4)
    for (const [name, wav] of inputs) {
      for (const sensitivity of ["strict", "balanced", "distant"] as const) {
        const expected = referencePreprocess(wav, sensitivity)
        const actual = preprocessWav(wav, sensitivity)
        expect({ name, silent: actual.silent }).toEqual({ name, silent: expected.silent })
        expect(Buffer.compare(actual.wav, expected.wav)).toBe(0)
      }
    }
  })

  test("handles an upload whose samples start at an odd memory offset", () => {
    const [, wav] = synthetic()[0]
    const backing = Buffer.alloc(wav.length + 1)
    wav.copy(backing, 1)
    const unaligned = backing.subarray(1)
    expect(unaligned.byteOffset % 2).toBe(1)
    const actual = preprocessWav(unaligned)
    expect(Buffer.compare(actual.wav, referencePreprocess(wav, "balanced").wav)).toBe(0)
  })

  test("does not modify the uploaded buffer", () => {
    const [, wav] = synthetic()[0]
    const before = Buffer.from(wav)
    preprocessWav(wav, "distant")
    expect(Buffer.compare(wav, before)).toBe(0)
  })
})
