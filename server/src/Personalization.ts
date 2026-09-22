export type WritingStyle = "automatic" | "formal" | "casual" | "veryCasual" | "excited"

export interface PersonalizationResult {
  readonly text: string
  readonly appliedSnippetTriggers: readonly string[]
}

/**
 * Apply user-authored snippet expansions after cleanup. Exact whole-utterance
 * triggers win so saved signatures and addresses are returned byte-for-byte.
 */
export function expandSnippets(
  text: string,
  snippets: Readonly<Record<string, string>> = {},
): PersonalizationResult {
  const entries = Object.entries(snippets)
    .filter((entry): entry is [string, string] => typeof entry[1] === "string")
    .map(([trigger, expansion]) => [trigger.trim(), expansion] as const)
    .filter(([trigger, expansion]) => trigger.length > 0 && expansion.trim().length > 0)
    .sort((a, b) => b[0].length - a[0].length)

  if (entries.length === 0) return { text, appliedSnippetTriggers: [] }

  const spoken = text.trim()
  const spokenWithoutFinalPunctuation = spoken.replace(/[.!?]+$/u, "").trim()
  for (const [trigger, expansion] of entries) {
    if (spokenWithoutFinalPunctuation.localeCompare(trigger, undefined, { sensitivity: "accent" }) === 0) {
      return { text: expansion, appliedSnippetTriggers: [trigger] }
    }
  }

  let result = text
  const applied: string[] = []
  for (const [trigger, expansion] of entries) {
    const escaped = trigger.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
    const pattern = new RegExp(`(^|\\s)(${escaped})(?=$|[\\s,.;:!?])`, "giu")
    if (!pattern.test(result)) continue
    pattern.lastIndex = 0
    result = result.replace(pattern, (_match, prefix: string) => `${prefix}${expansion}`)
    applied.push(trigger)
  }
  return { text: result, appliedSnippetTriggers: applied }
}

/** Meaning-preserving punctuation and casing profiles, applied on the server. */
export function applyWritingStyle(text: string, style: WritingStyle = "automatic"): string {
  const trimmed = text.trim()
  if (!trimmed || style === "automatic" || style === "formal") return trimmed

  if (style === "casual") {
    return sentenceCount(trimmed) <= 10 ? trimmed.replace(/\.$/u, "") : trimmed
  }

  if (style === "veryCasual") {
    const withoutPeriod = trimmed.replace(/\.$/u, "")
    return withoutPeriod.replace(/^\p{Lu}/u, (letter) => letter.toLocaleLowerCase())
  }

  if (style === "excited") {
    if (/[!?]$/u.test(trimmed)) return trimmed
    return trimmed.replace(/\.$/u, "") + "!"
  }

  return trimmed
}

function sentenceCount(text: string): number {
  return Math.max(1, text.split(/[.!?]+(?:\s+|$)/u).filter(Boolean).length)
}
