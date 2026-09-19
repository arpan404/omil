import path from "node:path"
import { DEFAULT_LLM, DEFAULT_WHISPER, modelSpec } from "./Config"

/**
 * Mutable server state: selected Whisper/LLM models + custom cleanup prompt.
 * Persisted in the data dir; the Mac app drives changes over the API.
 */

export interface ModelSelection { whisper: string; llm: string }

const SELECTION_FILE = "selected-models.json"
const PROMPT_FILE = "system-prompt.md"

export async function loadSelection(dataDir: string): Promise<ModelSelection> {
  const sel: ModelSelection = { whisper: DEFAULT_WHISPER, llm: DEFAULT_LLM }
  try {
    const raw = await Bun.file(path.join(dataDir, SELECTION_FILE)).json() as Partial<ModelSelection>
    if (raw.whisper && modelSpec(raw.whisper)?.kind === "whisper") sel.whisper = raw.whisper
    if (raw.llm && modelSpec(raw.llm)?.kind === "llm") sel.llm = raw.llm
  } catch { /* defaults */ }
  // Env overrides (CLI / tests).
  if (process.env.OMIL_WHISPER_MODEL && modelSpec(process.env.OMIL_WHISPER_MODEL)?.kind === "whisper") {
    sel.whisper = process.env.OMIL_WHISPER_MODEL
  }
  if (process.env.OMIL_LLM_MODEL && modelSpec(process.env.OMIL_LLM_MODEL)?.kind === "llm") {
    sel.llm = process.env.OMIL_LLM_MODEL
  }
  return sel
}

export async function saveSelection(dataDir: string, sel: ModelSelection): Promise<void> {
  await Bun.write(path.join(dataDir, SELECTION_FILE), JSON.stringify(sel, null, 2))
}

export async function loadPrompt(dataDir: string): Promise<{ text: string; isCustom: boolean }> {
  try {
    const text = await Bun.file(path.join(dataDir, PROMPT_FILE)).text()
    if (text.trim().length > 0) return { text, isCustom: true }
  } catch { /* default */ }
  const { DEFAULT_SYSTEM_PROMPT } = await import("./QwenCleanup")
  return { text: DEFAULT_SYSTEM_PROMPT, isCustom: false }
}

export async function savePrompt(dataDir: string, text: string): Promise<void> {
  await Bun.write(path.join(dataDir, PROMPT_FILE), text)
}

export async function resetPrompt(dataDir: string): Promise<void> {
  const { rm } = await import("node:fs/promises")
  await rm(path.join(dataDir, PROMPT_FILE), { force: true })
}
