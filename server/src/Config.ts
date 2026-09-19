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
  readonly expectedBytes: number
  readonly description: string
}

export const MODELS: ReadonlyArray<ModelSpec> = [
  {
    id: "whisper-large-v3-turbo",
    kind: "whisper",
    url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin",
    filename: "ggml-large-v3-turbo.bin",
    expectedBytes: 1_624_345_968,
    description: "OpenAI Whisper large-v3-turbo (809M params), whisper.cpp format",
  },
  {
    id: "qwen3-4b-instruct",
    kind: "llm",
    url: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
    filename: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
    expectedBytes: 2_497_281_120,
    description: "Qwen3 4B Instruct (2507), Q4_K_M GGUF, unsloth quant of Apache-2.0 weights",
  },
]

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
