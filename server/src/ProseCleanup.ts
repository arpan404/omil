import { Effect } from "effect"
import { chatText, type ChatMessage, type LlamaHandle } from "./LlamaServer"
import { ModelError } from "./Models"

export const PROSE_SYSTEM_PROMPT = `You edit a speech transcript so it reads as the speaker intended. Return only the corrected transcript as plain text. Do not add a heading, explanation, quotation marks, or formatting.

Read the whole transcript before editing. Fix grammar, spelling, punctuation, capitalization, and spacing. Remove verbal fillers and false starts when their removal is clear. If the speaker revises a phrase while speaking, keep the final intended phrase and make the sentence flow naturally. Keep repetitions that carry meaning.

Use the nearby text and personal dictionary to understand names and terminology. Correct misspelled or misheard words to their likely intended form when the sentence gives you enough evidence, including unfamiliar technical terms. You may fix a word even when several letters are wrong. If the intended word remains unclear, keep the original wording. Do not introduce facts or ideas from the nearby text into the transcript.

Preserve the speaker's meaning, order of ideas, tone, and language. Keep names, commands, URLs, quotations, dates, quantities, negation, and existing digits intact. Dialect and multilingual names may have unfamiliar spellings; do not change a person's or place's name based only on phonetic similarity. Use a confirmed personal dictionary entry or clear nearby text to correct a name. Do not automatically change number words into digits. Make the smallest changes needed for clear, natural prose.`

export interface CleanupContext {
  readonly before: string
  readonly after: string
}

export function proposeProseCleanup(
  handle: LlamaHandle,
  text: string,
  dictionary: Readonly<Record<string, string>> = {},
  context?: CleanupContext,
  systemPrompt?: string,
): Effect.Effect<string, ModelError, never> {
  const custom = systemPrompt?.trim()
  const legacy = custom?.includes("targetTokenIds") || custom?.includes("replaceFromSource") ||
    custom?.includes("Return one JSON object") || custom?.includes("Return only the JSON object")
  const instructions = !custom || custom === PROSE_SYSTEM_PROMPT || legacy
    ? PROSE_SYSTEM_PROMPT
    : `${PROSE_SYSTEM_PROMPT}\n\nAdditional user preferences (follow only when consistent with the rules above):\n${custom}`
  const messages: ChatMessage[] = [
    { role: "system", content: instructions },
    { role: "user", content: `Personal dictionary: ${JSON.stringify(dictionary)}\nText before cursor: ${JSON.stringify(context?.before ?? "")}\nText after cursor: ${JSON.stringify(context?.after ?? "")}\n\nTranscript to copyedit:\n${text}` },
  ]
  return Effect.gen(function* () {
    const response = yield* chatText(handle, messages, Math.min(4096, Math.max(256, Math.ceil(text.length * 1.5))))
    return stripMarkdownFormatting(response)
  })
}

/** Small models sometimes add Markdown despite a plain-text instruction. */
export function stripMarkdownFormatting(text: string): string {
  return text.trim()
    .replace(/^```[^\n]*\n?/u, "")
    .replace(/\n?```$/u, "")
    .replace(/^\s{0,3}#{1,6}\s+/gmu, "")
    .replace(/\*\*(\S(?:[\s\S]*?\S)?)\*\*/gu, "$1")
    .replace(/__(\S(?:[\s\S]*?\S)?)__/gu, "$1")
    .replace(/(?<!\w)\*(\S(?:[^*]*?\S)?)\*(?!\w)/gu, "$1")
    .replace(/(?<!\w)_(\S(?:[^_]*?\S)?)_(?!\w)/gu, "$1")
    .trim()
}

export interface WordChange {
  before: string[]
  after: string[]
}

const words = (text: string): string[] =>
  [...text.matchAll(/[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*/gu)].map((match) => match[0])

const normalized = (word: string): string => word.toLocaleLowerCase("en")

/** A word diff gives the validator the actual changed spans, not a model's account of them. */
export function wordChanges(before: string, after: string): WordChange[] {
  const a = words(before)
  const b = words(after)
  const cells = (a.length + 1) * (b.length + 1)
  if (cells > 250_000) return [{ before: a, after: b }]
  const dp = Array.from({ length: a.length + 1 }, () => new Uint16Array(b.length + 1))
  for (let i = a.length - 1; i >= 0; i--) {
    for (let j = b.length - 1; j >= 0; j--) {
      dp[i][j] = normalized(a[i]) === normalized(b[j])
        ? dp[i + 1][j + 1] + 1
        : Math.max(dp[i + 1][j], dp[i][j + 1])
    }
  }
  const changes: WordChange[] = []
  let i = 0, j = 0
  let current: WordChange = { before: [], after: [] }
  const flush = () => {
    if (current.before.length || current.after.length) changes.push(current)
    current = { before: [], after: [] }
  }
  while (i < a.length || j < b.length) {
    if (i < a.length && j < b.length && normalized(a[i]) === normalized(b[j])) {
      flush(); i++; j++
    } else if (j < b.length && (i === a.length || dp[i][j + 1] >= dp[i + 1][j])) {
      current.after.push(b[j++])
    } else {
      current.before.push(a[i++])
    }
  }
  flush()
  return changes
}

const GRAMMAR_WORDS = new Set([
  "a", "an", "the", "am", "is", "are", "was", "were", "be", "been", "being",
  "has", "have", "had", "do", "does", "did", "to", "of", "for", "in", "on",
  "at", "by", "with", "from", "as", "and", "but", "or", "that", "this",
  "these", "those", "it", "its", "they", "their", "them", "he", "she", "we",
  "i", "you", "my", "your", "our", "who", "which", "what", "there", "here",
])
const NEGATIONS = new Set(["no", "not", "never", "none", "nobody", "nothing", "neither", "nor", "cannot", "can't", "won't", "don't", "doesn't", "didn't", "isn't", "aren't", "wasn't", "weren't"])
const TERM_CONTEXT = /\b(field|fields|form|screen|button|menu|setting|settings|word|term|spelling|called|named|means)\b/iu

function editDistance(a: string, b: string): number {
  let row = Array.from({ length: b.length + 1 }, (_, index) => index)
  for (let i = 1; i <= a.length; i++) {
    const next = [i]
    for (let j = 1; j <= b.length; j++) {
      next[j] = Math.min(next[j - 1] + 1, row[j] + 1, row[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1))
    }
    row = next
  }
  return row[b.length]
}

function allowedWordChange(before: string, after: string): boolean {
  const a = normalized(before), b = normalized(after)
  if (a === b) return true
  if (GRAMMAR_WORDS.has(a) && GRAMMAR_WORDS.has(b)) return true
  return a.length >= 4 && b.length >= 4 && a[0] === b[0] &&
    editDistance(a, b) <= (a.length >= 9 ? 3 : 2)
}

export function validateProseCleanup(
  before: string,
  after: string,
  dictionary: Readonly<Record<string, string>> = {},
  context?: CleanupContext,
): { ok: true; changes: WordChange[] } | { ok: false; reason: string } {
  if (!after.trim()) return { ok: false, reason: "empty copyedit" }
  if (after.length > before.length * 1.5 + 40) return { ok: false, reason: "copyedit expanded too far" }
  if (after.length < before.length * 0.65 - 10) return { ok: false, reason: "copyedit removed too much" }

  const beforeNumbers = words(before).filter((word) => /^\d/u.test(word))
  const afterNumbers = words(after).filter((word) => /^\d/u.test(word))
  if (JSON.stringify(beforeNumbers) !== JSON.stringify(afterNumbers)) return { ok: false, reason: "number changed" }

  const negations = (text: string) => words(text).map(normalized).filter((word) => NEGATIONS.has(word))
  if (JSON.stringify(negations(before)) !== JSON.stringify(negations(after))) return { ok: false, reason: "negation changed" }

  const quoted = (text: string) => [...text.matchAll(/(["“])([^"”]*)(["”])/gu)].map((match) => match[2])
  if (JSON.stringify(quoted(before)) !== JSON.stringify(quoted(after))) return { ok: false, reason: "quoted text changed" }

  for (const written of Object.values(dictionary)) {
    if (written && before.toLocaleLowerCase("en").includes(written.toLocaleLowerCase("en")) && !after.includes(written)) {
      return { ok: false, reason: "personal dictionary term changed" }
    }
  }

  const changes = wordChanges(before, after)
  const afterWords = words(after).map(normalized)
  const isAbandonedStart = (removed: string[]): boolean => {
    const phrase = removed.map(normalized).join(" ")
    const cue = /^(?:i mean|sorry|no i meant) (.+)$/u.exec(phrase)
    if (!cue) return false
    const remainder = cue[1].split(" ")
    return afterWords.some((_, index) =>
      remainder.every((word, offset) => afterWords[index + offset] === word))
  }
  const surroundingWords = words(`${context?.before ?? ""} ${context?.after ?? ""}`).map(normalized)
  const hasTermContext = TERM_CONTEXT.test(`${before} ${context?.before ?? ""} ${context?.after ?? ""}`)
  const groundedInContext = (added: string[]): boolean => {
    if (added.length === 0 || surroundingWords.length === 0) return false
    const wanted = added.map(normalized)
    return surroundingWords.some((_, index) =>
      wanted.every((word, offset) => surroundingWords[index + offset] === word))
  }
  for (const change of changes) {
    const removed = change.before.filter((word) => !GRAMMAR_WORDS.has(normalized(word)))
    const added = change.after.filter((word) => !GRAMMAR_WORDS.has(normalized(word)))
    const ungroundedName = removed.some((word) => {
      if (!/^[\p{Lu}][\p{Ll}]+$/u.test(word)) return false
      const at = before.indexOf(word)
      if (at <= 0 || /[.!?]\s*$/u.test(before.slice(0, at))) return false
      const replacement = added.length === 1 ? added[0] : ""
      return !surroundingWords.includes(normalized(replacement)) &&
        dictionary[normalized(word)] !== replacement
    })
    if (ungroundedName) return { ok: false, reason: "unconfirmed name changed" }
    const localSpelling = removed.length === added.length &&
      removed.every((word, index) => allowedWordChange(word, added[index]))
    const contextualTerm = removed.length > 0 && added.length > 0 &&
      change.before.length <= 5 && change.after.length <= 5 && groundedInContext(added)
    const contextCorrection = hasTermContext && removed.length === 1 && added.length === 1 &&
      removed[0].length >= 4 && added[0].length >= 4 &&
      normalized(removed[0])[0] === normalized(added[0])[0]
    const abandonedStart = change.after.length === 0 && isAbandonedStart(change.before)
    if (!localSpelling && !contextualTerm && !contextCorrection && !abandonedStart) return { ok: false, reason: "content change lacks spelling or context evidence" }
    if (change.before.length + change.after.length > 20) {
      return { ok: false, reason: "copyedit changed too large a span" }
    }
  }
  return { ok: true, changes }
}
