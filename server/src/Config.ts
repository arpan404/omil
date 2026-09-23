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
}

const WHISPER_REPO = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

export const MODELS: ReadonlyArray<ModelSpec> = [
  {
    id: "whisper-tiny", kind: "whisper",
    url: `${WHISPER_REPO}/ggml-tiny.bin`, filename: "ggml-tiny.bin",
    expectedBytes: null, description: "Whisper tiny (39M) — fastest, lowest accuracy",
  },
  {
    id: "whisper-base", kind: "whisper",
    url: `${WHISPER_REPO}/ggml-base.bin`, filename: "ggml-base.bin",
    expectedBytes: null, description: "Whisper base (74M) — fast draft quality",
  },
  {
    id: "whisper-small", kind: "whisper",
    url: `${WHISPER_REPO}/ggml-small.bin`, filename: "ggml-small.bin",
    expectedBytes: null, description: "Whisper small (244M) — balanced",
  },
  {
    id: "whisper-medium", kind: "whisper",
    url: `${WHISPER_REPO}/ggml-medium.bin`, filename: "ggml-medium.bin",
    expectedBytes: null, description: "Whisper medium (769M) — high accuracy, slower",
  },
  {
    id: "distil-whisper-medium-en", kind: "whisper",
    url: "https://huggingface.co/distil-whisper/distil-medium.en/resolve/main/ggml-medium-32-2.en.bin",
    filename: "ggml-medium-32-2.en.bin",
    expectedBytes: 794_018_180,
    description: "Distil-Whisper medium English — fast English transcription from Hugging Face",
  },
  {
    id: "distil-whisper-large-v3", kind: "whisper",
    url: "https://huggingface.co/distil-whisper/distil-large-v3-ggml/resolve/main/ggml-distil-large-v3.bin",
    filename: "ggml-distil-large-v3.bin",
    expectedBytes: 1_519_521_155,
    description: "Distil-Whisper large-v3 English — faster long-form English model from Hugging Face",
  },
  {
    id: "whisper-large-v3", kind: "whisper",
    url: `${WHISPER_REPO}/ggml-large-v3.bin`, filename: "ggml-large-v3.bin",
    expectedBytes: null, description: "OpenAI Whisper large-v3 (1.55B) — most accurate",
  },
  {
    id: "whisper-large-v3-q5", kind: "whisper",
    url: `${WHISPER_REPO}/ggml-large-v3-q5_0.bin`,
    filename: "ggml-large-v3-q5_0.bin",
    expectedBytes: null,
    description: "Whisper large-v3 Q5 — high accuracy with a smaller memory footprint",
  },
  {
    id: "whisper-large-v3-turbo",
    kind: "whisper",
    url: `${WHISPER_REPO}/ggml-large-v3-turbo.bin`,
    filename: "ggml-large-v3-turbo.bin",
    expectedBytes: 1_624_345_968,
    description: "OpenAI Whisper large-v3-turbo (809M params), whisper.cpp format",
  },
  {
    id: "whisper-large-v3-turbo-q5", kind: "whisper",
    url: `${WHISPER_REPO}/ggml-large-v3-turbo-q5_0.bin`,
    filename: "ggml-large-v3-turbo-q5_0.bin",
    expectedBytes: null,
    description: "Whisper large-v3-turbo Q5 — recommended balance of speed, size, and accuracy",
  },
  {
    id: "whisper-large-v3-turbo-q8", kind: "whisper",
    url: `${WHISPER_REPO}/ggml-large-v3-turbo-q8_0.bin`,
    filename: "ggml-large-v3-turbo-q8_0.bin",
    expectedBytes: null,
    description: "Whisper large-v3-turbo Q8 — smaller than full precision with higher fidelity than Q5",
  },
  {
    id: "qwen3-0.6b",
    kind: "llm",
    url: "https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_K_M.gguf",
    filename: "Qwen3-0.6B-Q4_K_M.gguf",
    expectedBytes: 396_705_472,
    description: "Qwen3 0.6B Instruct, Q4_K_M — tiny, fast, lower repair quality",
  },
  {
    id: "qwen3-4b-instruct",
    kind: "llm",
    url: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
    filename: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
    expectedBytes: 2_497_281_120,
    description: "Qwen3 4B Instruct (2507), Q4_K_M GGUF, unsloth quant of Apache-2.0 weights",
  },
  {
    id: "qwen3-8b",
    kind: "llm",
    url: "https://huggingface.co/unsloth/Qwen3-8B-GGUF/resolve/main/Qwen3-8B-Q4_K_M.gguf",
    filename: "Qwen3-8B-Q4_K_M.gguf",
    expectedBytes: 5_027_784_512,
    description: "Qwen3 8B Instruct, Q4_K_M — best repair quality, needs 8GB+ headroom",
  },
  {
    id: "qwen3.5-0.8b", kind: "llm",
    url: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf",
    filename: "Qwen3.5-0.8B-Q4_K_M.gguf",
    expectedBytes: null,
    description: "Qwen3.5 0.8B, Q4_K_M — newest compact option, requires current llama.cpp",
  },
  {
    id: "qwen3.5-4b", kind: "llm",
    url: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf",
    filename: "Qwen3.5-4B-Q4_K_M.gguf",
    expectedBytes: null,
    description: "Qwen3.5 4B, Q4_K_M — newer balanced cleanup model, requires current llama.cpp",
  },
  {
    id: "qwen3.5-9b", kind: "llm",
    url: "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf",
    filename: "Qwen3.5-9B-Q4_K_M.gguf",
    expectedBytes: null,
    description: "Qwen3.5 9B, Q4_K_M — highest-capacity catalog option, needs more memory",
  },
]

export const DEFAULT_WHISPER = "whisper-large-v3-turbo"
export const DEFAULT_LLM = "qwen3-4b-instruct"

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
    whisperModelId: process.env.OMIL_WHISPER_MODEL ?? "whisper-large-v3-turbo",
    llmModelId: process.env.OMIL_LLM_MODEL ?? "qwen3-4b-instruct",
  } satisfies ServerConfig
})

export const modelSpec = (id: string): ModelSpec | undefined =>
  MODELS.find((m) => m.id === id)

export { Cfg }
