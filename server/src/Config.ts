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
  readonly kind: "whisper" | "llm"
  readonly url: string
  readonly filename: string
  /** Exact size when pinned; null = accept server's content-length, SHA pinned on first download. */
  readonly expectedBytes: number | null
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
    id: "whisper-large-v3", kind: "whisper",
    url: `${WHISPER_REPO}/ggml-large-v3.bin`, filename: "ggml-large-v3.bin",
    expectedBytes: null, description: "OpenAI Whisper large-v3 (1.55B) — most accurate",
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
]

export const DEFAULT_WHISPER = "whisper-large-v3-turbo"
export const DEFAULT_LLM = "qwen3-4b-instruct"

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
