/** Mild filtering and level adjustment for Omil's 16 kHz mono PCM16 uploads. */
import { AUDIO_PROFILES, type AudioSensitivity } from "./AudioSensitivity"

interface PreprocessedAudio {
  readonly wav: Buffer
  readonly silent: boolean
}

interface PcmRange {
  readonly offset: number
  readonly bytes: number
}

const pcmRange = (wav: Buffer): PcmRange | null => {
  if (wav.length < 44 || wav.toString("ascii", 0, 4) !== "RIFF"
    || wav.toString("ascii", 8, 12) !== "WAVE") return null

  let format: { codec: number; channels: number; rate: number; bits: number } | null = null
  let data: PcmRange | null = null
  for (let offset = 12; offset + 8 <= wav.length;) {
    const size = wav.readUInt32LE(offset + 4)
    const body = offset + 8
    if (body + size > wav.length) return null
    const name = wav.toString("ascii", offset, offset + 4)
    if (name === "fmt " && size >= 16) {
      format = {
        codec: wav.readUInt16LE(body),
        channels: wav.readUInt16LE(body + 2),
        rate: wav.readUInt32LE(body + 4),
        bits: wav.readUInt16LE(body + 14),
      }
    } else if (name === "data") {
      data = { offset: body, bytes: size }
    }
    offset = body + size + (size & 1)
  }

  if (!format || format.codec !== 1 || format.channels !== 1
    || format.rate !== 16_000 || format.bits !== 16
    || !data || data.bytes % 2 !== 0) return null
  return data
}

const littleEndian = new Uint8Array(new Uint16Array([1]).buffer)[0] === 1

/** Samples as an Int16Array, viewing the upload in place when alignment and byte order allow. */
const samplesOf = (wav: Buffer, range: PcmRange): Int16Array => {
  const count = range.bytes / 2
  const byteOffset = wav.byteOffset + range.offset
  if (littleEndian && byteOffset % 2 === 0) return new Int16Array(wav.buffer, byteOffset, count)
  const copy = new Int16Array(count)
  for (let index = 0; index < count; index++) copy[index] = wav.readInt16LE(range.offset + index * 2)
  return copy
}

export const preprocessWav = (wav: Buffer, sensitivity: AudioSensitivity = "balanced"): PreprocessedAudio => {
  const profile = AUDIO_PROFILES[sensitivity]
  const range = pcmRange(wav)
  if (!range) return { wav, silent: false }
  // Omil captures at most ten minutes. Keep larger external uploads unchanged.
  if (range.bytes > 16_000 * 2 * 600) return { wav, silent: false }
  const count = range.bytes / 2
  if (count === 0) return { wav, silent: true }
  const samples = samplesOf(wav, range)

  const frameSize = 320 // 20 ms at 16 kHz
  const frameLevels: number[] = []
  const alpha = 1 / (1 + 2 * Math.PI * 80 / 16_000)
  let previousInput = 0
  let previousOutput = 0
  let frameSquares = 0
  let frameCount = 0
  let inputPeak = 0
  let filteredPeak = 0

  for (let index = 0; index < count; index++) {
    const sample = samples[index]
    inputPeak = Math.max(inputPeak, Math.abs(sample))
    const input = sample / 32_768
    const filtered = alpha * (previousOutput + input - previousInput)
    previousInput = input
    previousOutput = filtered
    filteredPeak = Math.max(filteredPeak, Math.abs(filtered))
    frameSquares += filtered * filtered
    frameCount++
    if (frameCount === frameSize || index === count - 1) {
      frameLevels.push(Math.sqrt(frameSquares / frameCount))
      frameSquares = 0
      frameCount = 0
    }
  }

  // An almost empty capture should never reach a generative decoder.
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

  // A fresh ArrayBuffer keeps the output sample view aligned; chunk offsets are always even.
  const result = Buffer.from(new ArrayBuffer(wav.length))
  result.set(wav.subarray(0, range.offset), 0)
  result.set(wav.subarray(range.offset + range.bytes), range.offset + range.bytes)
  const output = new Int16Array(result.buffer, range.offset, count)
  previousInput = 0
  previousOutput = 0
  for (let index = 0; index < count; index++) {
    const input = samples[index] / 32_768
    const filtered = alpha * (previousOutput + input - previousInput)
    previousInput = input
    previousOutput = filtered
    const adjusted = Math.round(filtered * gain * 32_768)
    output[index] = Math.max(-32_768, Math.min(32_767, adjusted))
  }
  if (!littleEndian) {
    for (let index = 0; index < count; index++) {
      result.writeInt16LE(output[index], range.offset + index * 2)
    }
  }
  return { wav: result, silent: false }
}
