export type AudioSensitivity = "strict" | "balanced" | "distant"

export interface AudioProfile {
  readonly vadThreshold: number
  readonly minSpeechMs: number
  readonly minSilenceMs: number
  readonly speechPadMs: number
  readonly silencePeak: number
  readonly minLevelChange: number
  readonly minimumFrameRms: number
  readonly dynamicRatio: number
  readonly maxGain: number
}

export const AUDIO_PROFILES: Record<AudioSensitivity, AudioProfile> = {
  strict: {
    vadThreshold: 0.65, minSpeechMs: 250, minSilenceMs: 100, speechPadMs: 30,
    silencePeak: 32, minLevelChange: 0.01, minimumFrameRms: 0.005,
    dynamicRatio: 4, maxGain: 2,
  },
  balanced: {
    vadThreshold: 0.5, minSpeechMs: 250, minSilenceMs: 100, speechPadMs: 30,
    silencePeak: 16, minLevelChange: 0.008, minimumFrameRms: 0.003,
    dynamicRatio: 3, maxGain: 3,
  },
  distant: {
    vadThreshold: 0.3, minSpeechMs: 120, minSilenceMs: 450, speechPadMs: 90,
    silencePeak: 8, minLevelChange: 0.004, minimumFrameRms: 0.0015,
    dynamicRatio: 2, maxGain: 5,
  },
}

export const parseAudioSensitivity = (value: string | null): AudioSensitivity | null => {
  if (value === null) return "balanced"
  return value === "strict" || value === "balanced" || value === "distant" ? value : null
}
