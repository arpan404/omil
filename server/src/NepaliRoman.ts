/**
 * Romanized Nepali: the Latin-script Nepali people type in chats
 * ("ma bholi office janchhu"). Whisper writes Nepali in Devanagari, so
 * transcripts for the `ne-Latn` language are converted here, with fixed
 * rules, before cleanup sees them.
 */

/** BCP 47 tag the clients send for Nepali written in Latin script. */
export const NEPALI_ROMAN = "ne-latn"

export const wantsNepaliRoman = (language: string): boolean =>
  language.trim().toLowerCase() === NEPALI_ROMAN

const CONSONANTS: Record<string, string> = {
  "क": "k", "ख": "kh", "ग": "g", "घ": "gh", "ङ": "ng",
  "च": "ch", "छ": "chh", "ज": "j", "झ": "jh", "ञ": "n",
  "ट": "t", "ठ": "th", "ड": "d", "ढ": "dh", "ण": "n",
  "त": "t", "थ": "th", "द": "d", "ध": "dh", "न": "n",
  "प": "p", "फ": "ph", "ब": "b", "भ": "bh", "म": "m",
  "य": "y", "र": "r", "ल": "l", "व": "w",
  "श": "sh", "ष": "sh", "स": "s", "ह": "h",
}
/** Consonant + nukta, as NFC leaves them decomposed. */
const NUKTA_FORMS: Record<string, string> = {
  "क": "k", "ख": "kh", "ग": "g", "ज": "z", "ड": "r", "ढ": "rh", "फ": "f", "य": "y",
}
const VOWELS: Record<string, string> = {
  "अ": "a", "आ": "aa", "इ": "i", "ई": "i", "उ": "u", "ऊ": "u", "ऋ": "ri",
  "ए": "e", "ऐ": "ai", "ओ": "o", "औ": "au", "ऑ": "o", "ऍ": "e",
}
// Casual spelling writes the vowel sign ा as a single "a" (खाना -> khana,
// नेपाल -> nepal) and keeps "aa" for a written आ (आज -> aaj).
const MATRAS: Record<string, string> = {
  "ा": "a", "ि": "i", "ी": "i", "ु": "u", "ू": "u", "ृ": "ri",
  "े": "e", "ै": "ai", "ो": "o", "ौ": "au", "ॉ": "o", "ॅ": "e",
}
const VIRAMA = "्"
const NUKTA = "़"
const ANUSVARA = "ं"
const CHANDRABINDU = "ँ"
const VISARGA = "ः"
const LABIALS = new Set(["प", "फ", "ब", "भ", "म"])
const DIGITS = "०१२३४५६७८९"

type Piece = { text: string; inherent?: true }

const isDevanagari = (char: string): boolean => {
  const code = char.codePointAt(0)!
  return code >= 0x0900 && code <= 0x097f && char !== "।" && char !== "॥"
}

/** One Devanagari word, with the spoken rules casual spelling follows. */
function romanizeWord(chars: string[]): string {
  const pieces: Piece[] = []
  let syllables = 0
  let finalConsonant = ""
  let finalInConjunct = false
  let afterVirama = false
  for (let i = 0; i < chars.length;) {
    const char = chars[i]
    if (VOWELS[char]) {
      pieces.push({ text: VOWELS[char] })
      syllables++
      afterVirama = false
      i++
      continue
    }
    if (CONSONANTS[char]) {
      let roman = CONSONANTS[char]
      let next = i + 1
      if (chars[next] === NUKTA) {
        roman = NUKTA_FORMS[char] ?? roman
        next++
      }
      // ज्ञ is said "gy" in Nepali: ज्ञान -> gyan.
      if (char === "ज" && chars[next] === VIRAMA && chars[next + 1] === "ञ") {
        roman = "gy"
        next += 2
      }
      pieces.push({ text: roman })
      finalConsonant = char
      finalInConjunct = afterVirama
      const sign = chars[next]
      if (sign && MATRAS[sign]) {
        pieces.push({ text: MATRAS[sign] })
        syllables++
        afterVirama = false
        next++
      } else if (sign === VIRAMA) {
        afterVirama = true
        next++
      } else {
        pieces.push({ text: "a", inherent: true })
        syllables++
        afterVirama = false
      }
      i = next
      continue
    }
    if (char === ANUSVARA || char === CHANDRABINDU) {
      const following = chars.slice(i + 1).find((c) => CONSONANTS[c])
      pieces.push({ text: char === ANUSVARA && following && LABIALS.has(following) ? "m" : "n" })
    } else if (char === VISARGA) {
      pieces.push({ text: "h" })
    } else if (DIGITS.includes(char)) {
      pieces.push({ text: String(DIGITS.indexOf(char)) })
    } else if (char === "ॐ") {
      pieces.push({ text: "om" })
    }
    // Other signs (nukta on a vowel, avagraha, joiners) are not spoken.
    afterVirama = false
    i++
  }

  // A word-final inherent "a" is silent (घर -> ghar), except in one-syllable
  // words (छ -> chha), after a conjunct (सम्म -> samma), and after छ, which
  // keeps it in verb endings (गएछ -> gaechha).
  const last = pieces[pieces.length - 1]
  if (last?.inherent && syllables > 1 && !finalInConjunct && finalConsonant !== "छ") {
    pieces.pop()
  }

  return pieces.map((piece) => piece.text).join("")
}

/** Converts Devanagari in `text` to romanized Nepali; other text is kept. */
export function romanizeNepali(text: string): string {
  const chars = [...text.normalize("NFC")]
  let out = ""
  for (let i = 0; i < chars.length;) {
    if (isDevanagari(chars[i])) {
      const start = i
      while (i < chars.length && isDevanagari(chars[i])) i++
      out += romanizeWord(chars.slice(start, i))
      continue
    }
    out += chars[i] === "।" || chars[i] === "॥" ? "." : chars[i]
    i++
  }
  return out
}

/**
 * A spelling-independent key for comparing romanized and English spellings
 * of one spoken word: ophis and office, kol and call, miting and meeting all
 * share a key. Only consonant sounds are kept, after the first letter.
 */
export function soundKey(word: string): string {
  let w = word.toLowerCase()
  if (/[^a-z]/u.test(w)) return w
  w = w
    .replace(/sch/gu, "sk")
    .replace(/chh|ch/gu, "C")
    .replace(/c(?=[eiy])/gu, "s")
    .replace(/ck|c|q/gu, "k")
    .replace(/g(?=[ei])/gu, "j")
    .replace(/x/gu, "ks")
    .replace(/sh/gu, "s")
    .replace(/ph/gu, "f")
    .replace(/([kgjtdb])h/gu, "$1")
    .replace(/z/gu, "j")
    .replace(/v/gu, "b")
  const first = /[aeiou]/u.test(w[0] ?? "") ? "_" : w[0] ?? ""
  const rest = w.slice(1).replace(/[aeiouyhw]/gu, "").replace(/(.)\1+/gu, "$1")
  return first + rest
}

/** Romanizes a Whisper transcript and its segments. */
export const romanizeTranscript = <T extends { text: string; segments: ReadonlyArray<{ text: string }> }>(t: T): T => ({
  ...t,
  text: romanizeNepali(t.text),
  segments: t.segments.map((segment) => ({ ...segment, text: romanizeNepali(segment.text) })),
})
