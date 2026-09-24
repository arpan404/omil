import { Effect, Config as Cfg } from "effect"

/**
 * Server configuration. All actual inference work happens here; Swift apps
 * are thin clients (capture, display, local insertion).
 *
 * Trust model: this server runs on the USER'S OWN Mac on their LAN.
 * iPhone/iPad audio travels to it. That is a deliberate change from pure
 * on-device: no third-party server is ever involved, but the Mac must be
 * reachable and the LAN trusted.
 */

export interface ModelSpec {
  readonly id: string
  readonly kind: "whisper" | "llm" | "vad"
  readonly url: string
  readonly filename: string
  /** Exact size when pinned; null = accept server's content-length, SHA pinned on first download. */
  readonly expectedBytes: number | null
  readonly expectedSha256?: string
  readonly description: string
  /** Distilled Whisper is English-only; the other curated Whisper models are multilingual. */
  readonly language?: "en"
}

const WHISPER_REPO = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

export const MODELS: ReadonlyArray<ModelSpec> = [
  {
    id: "whisper-base-q8", kind: "whisper",
    url: `${WHISPER_REPO}/ggml-base-q8_0.bin`,
    filename: "ggml-base-q8_0.bin",
    expectedBytes: 81_768_585,
    expectedSha256: "c577b9a86e7e048a0b7eada054f4dd79a56bbfa911fbdacf900ac5b567cbb7d9",
    description: "Whisper base Q8 — compact multilingual transcription",
  },
  {
    id: "whisper-small-q8", kind: "whisper",
    url: `${WHISPER_REPO}/ggml-small-q8_0.bin`,
    filename: "ggml-small-q8_0.bin",
    expectedBytes: 264_464_607,
    expectedSha256: "49c8fb02b65e6049d5fa6c04f81f53b867b5ec9540406812c643f177317f779f",
    description: "Whisper small Q8 — faster transcription with a smaller 8-bit model",
  },
  {
    id: "whisper-medium-q8", kind: "whisper",
    url: `${WHISPER_REPO}/ggml-medium-q8_0.bin`,
    filename: "ggml-medium-q8_0.bin",
    expectedBytes: 823_369_779,
    expectedSha256: "42a1ffcbe4167d224232443396968db4d02d4e8e87e213d3ee2e03095dea6502",
    description: "Whisper medium Q8 — larger multilingual model",
  },
  {
    id: "whisper-large-v3-turbo-q8", kind: "whisper",
    url: `${WHISPER_REPO}/ggml-large-v3-turbo-q8_0.bin`,
    filename: "ggml-large-v3-turbo-q8_0.bin",
    expectedBytes: 874_188_075,
    expectedSha256: "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1",
    description: "Whisper large-v3 turbo Q8 — accurate 8-bit transcription",
  },
  {
    id: "whisper-large-v3-q5", kind: "whisper",
    url: `${WHISPER_REPO}/ggml-large-v3-q5_0.bin`,
    filename: "ggml-large-v3-q5_0.bin",
    expectedBytes: 1_081_140_203,
    expectedSha256: "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1",
    description: "Whisper large-v3 Q5 — full large-v3 model in 5-bit weights",
  },
  {
    id: "whisper-distil-large-v3", kind: "whisper",
    url: "https://huggingface.co/distil-whisper/distil-large-v3-ggml/resolve/main/ggml-distil-large-v3.bin",
    filename: "ggml-distil-large-v3.bin",
    expectedBytes: 1_519_521_155,
    expectedSha256: "2883a11b90fb10ed592d826edeaee7d2929bf1ab985109fe9e1e7b4d2b69a298",
    description: "Distil-Whisper large-v3 — English-only distilled model for whisper.cpp",
    language: "en",
  },
  {
    id: "qwen3.5-0.8b", kind: "llm",
    url: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf",
    filename: "Qwen3.5-0.8B-Q4_K_M.gguf",
    expectedBytes: 532_517_120,
    expectedSha256: "bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517",
    description: "Qwen3.5 0.8B, Q4_K_M — newest compact option, requires current llama.cpp",
  },
  {
    id: "qwen3.5-2b", kind: "llm",
    url: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf",
    filename: "Qwen3.5-2B-Q4_K_M.gguf",
    expectedBytes: 1_280_835_840,
    expectedSha256: "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223",
    description: "Qwen3.5 2B, Q4_K_M — faster cleanup with 4-bit weights",
  },
  {
    id: "qwen3.5-4b", kind: "llm",
    url: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf",
    filename: "Qwen3.5-4B-Q4_K_M.gguf",
    expectedBytes: 2_740_937_888,
    expectedSha256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4",
    description: "Qwen3.5 4B, Q4_K_M — newer balanced cleanup model, requires current llama.cpp",
  },
  {
    id: "qwen3.5-9b", kind: "llm",
    url: "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf",
    filename: "Qwen3.5-9B-Q4_K_M.gguf",
    expectedBytes: 5_680_522_464,
    expectedSha256: "03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8",
    description: "Qwen3.5 9B, Q4_K_M — larger cleanup model for Macs with enough memory",
  },
  {
    id: "llama-3.1-8b-instruct", kind: "llm",
    url: "https://huggingface.co/unsloth/Llama-3.1-8B-Instruct-GGUF/resolve/main/Llama-3.1-8B-Instruct-Q4_K_M.gguf",
    filename: "Llama-3.1-8B-Instruct-Q4_K_M.gguf",
    expectedBytes: 4_920_739_200,
    expectedSha256: "b3bdbf23b47d7e6bb791c99b206deb169cd5a96362a9e3399028df2faacdc506",
    description: "Llama 3.1 8B Instruct, Q4_K_M — Meta Llama 3.1 license",
  },
  {
    id: "gemma-3-4b-it", kind: "llm",
    url: "https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf",
    filename: "gemma-3-4b-it-Q4_K_M.gguf",
    expectedBytes: 2_489_757_856,
    expectedSha256: "882e8d2db44dc554fb0ea5077cb7e4bc49e7342a1f0da57901c0802ea21a0863",
    description: "Gemma 3 4B Instruct, Q4_K_M — Google Gemma license",
  },
]

export const DEFAULT_WHISPER = "whisper-large-v3-turbo-q8"
export const DEFAULT_LLM = "qwen3.5-2b"

// Internal preprocessing asset, intentionally absent from the user model catalog.
export const VAD_MODEL: ModelSpec = {
  id: "silero-vad-v6.2.0",
  kind: "vad",
  url: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin",
  filename: "ggml-silero-v6.2.0.bin",
  expectedBytes: 885_098,
  expectedSha256: "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987",
  description: "Silero voice activity detector for whisper.cpp",
}

export interface ServerConfig {
  readonly host: string
  readonly port: number
  readonly dataDir: string
  readonly whisperBin: string
  readonly llamaBin: string
  readonly llamaPort: number
  readonly whisperModelId: string
  readonly llmModelId: string
}

export const loadConfig = Effect.gen(function* () {
  const dataDir =
    process.env.OMIL_DATA ?? `${process.cwd()}/data`
  return {
    host: process.env.OMIL_HOST ?? "127.0.0.1",
    port: Number(process.env.OMIL_PORT ?? 3217),
    dataDir,
    whisperBin: process.env.OMIL_WHISPER_BIN ?? "whisper-cli",
    llamaBin: process.env.OMIL_LLAMA_BIN ?? "llama-server",
    llamaPort: Number(process.env.OMIL_LLAMA_PORT ?? 3218),
    whisperModelId: process.env.OMIL_WHISPER_MODEL ?? DEFAULT_WHISPER,
    llmModelId: process.env.OMIL_LLM_MODEL ?? DEFAULT_LLM,
  } satisfies ServerConfig
})

export const modelSpec = (id: string): ModelSpec | undefined =>
  MODELS.find((m) => m.id === id)

export { Cfg }
