import { describe, expect, test } from "bun:test"
import { romanizeNepali, romanizeTranscript, soundKey, wantsNepaliRoman } from "../src/NepaliRoman"
import { salvageCopyedit, validateProseCleanup } from "../src/ProseCleanup"
import { normalizeWhisperLanguage } from "../src/Whisper"

describe("romanized Nepali", () => {
  test("writes Devanagari the way Nepali speakers type it", () => {
    expect(romanizeNepali("आज मलाई धेरै काम छ, त्यसैले म साँझ सम्म फ्री हुन्न। तिमी कहिले घर आउँछौ?"))
      .toBe("aaj malai dherai kam chha, tyasaile ma sanjh samma phri hunna. timi kahile ghar aaunchhau?")
  })

  test("keeps English words that are already in Latin script", () => {
    expect(romanizeNepali("म भोलि office जान्छु, अनि meeting सकिएपछि तिमीलाई call गर्छु। खाना खायौ?"))
      .toBe("ma bholi office janchhu, ani meeting sakiepachhi timilai call garchhu. khana khayau?")
  })

  test("drops a silent final a but keeps it in one-syllable words, conjuncts, and after chh", () => {
    expect(romanizeNepali("घर")).toBe("ghar")
    expect(romanizeNepali("छ")).toBe("chha")
    expect(romanizeNepali("सम्म")).toBe("samma")
    expect(romanizeNepali("गएछ")).toBe("gaechha")
  })

  test("handles conjuncts, nasals, nukta, and digits", () => {
    expect(romanizeNepali("ज्ञान संसार सम्बन्ध क्षमा ज़िन्दगी २०८१")).toBe("gyan sansar sambandha kshama zindagi 2081")
  })

  test("romanizes every segment of a transcript", () => {
    const t = romanizeTranscript({ text: "नमस्ते", segments: [{ start: 0, end: 1, text: "नमस्ते" }], model: "m" })
    expect(t.text).toBe("namaste")
    expect(t.segments[0]).toEqual({ start: 0, end: 1, text: "namaste" })
  })

  test("is requested with the ne-Latn tag, which Whisper hears as Nepali", () => {
    expect(wantsNepaliRoman("ne-Latn")).toBe(true)
    expect(wantsNepaliRoman("ne")).toBe(false)
    expect(normalizeWhisperLanguage("ne-Latn")).toBe("ne")
  })

  test("gives Nepali and English spellings of one word the same sound key", () => {
    for (const [nepali, english] of [["ophis", "office"], ["kol", "call"], ["miting", "meeting"], ["phri", "free"], ["skul", "school"], ["kampyutar", "computer"]]) {
      expect(soundKey(nepali)).toBe(soundKey(english))
    }
    expect(soundKey("kol")).not.toBe(soundKey("garchhu"))
  })
})

describe("romanized Nepali copyedit", () => {
  const nepali = { nepaliRoman: true }

  test("accepts English words restored to English spelling", () => {
    const result = validateProseCleanup(
      "ma bholi ophis janchhu ani miting pachhi timilai kol garchhu",
      "Ma bholi office janchhu, ani meeting pachhi timilai call garchhu.",
      {}, undefined, nepali,
    )
    expect(result.ok).toBe(true)
  })

  test("accepts a word Whisper split in two", () => {
    expect(validateProseCleanup("timilai ko ol garchhu", "timilai call garchhu", {}, undefined, nepali).ok).toBe(true)
  })

  test("rejects translating Nepali into English", () => {
    const result = validateProseCleanup("timi kahile ghar aaunchhau", "When will you come home?", {}, undefined, nepali)
    expect(result.ok).toBe(false)
  })

  test("rejects a Nepali word swapped for a similar-sounding English one", () => {
    const result = validateProseCleanup("timi lai kam chha", "time lai come chha", {}, undefined, nepali)
    expect(result).toEqual({ ok: false, reason: "Nepali word changed" })
  })

  test("rejects a changed verb ending or negative form", () => {
    for (const [before, after] of [["message pathaun sakin", "message pathaun sakun"], ["ma garchhu", "ma garchhau"], ["ma free hunna", "ma free huna"]]) {
      expect(validateProseCleanup(before, after, {}, undefined, nepali)).toEqual({ ok: false, reason: "Nepali word changed" })
    }
  })

  test("keeps the safe edits of a rejected copyedit", () => {
    const before = "mero lyapatap ma intaranet chalen, tyasaile mesej pathaun sakin"
    const after = "Mero laptop ma internet chalen, tyasaile message pathaun sakun."
    const salvaged = salvageCopyedit(before, after, {}, undefined, nepali)
    expect(salvaged).toBe("Mero laptop ma internet chalen, tyasaile message pathaun sakin.")
    expect(validateProseCleanup(before, salvaged, {}, undefined, nepali).ok).toBe(true)
  })

  test("restores dropped words and removes unsupported additions", () => {
    expect(salvageCopyedit("timi kahile ghar aaunchhau", "Timi kahile ghar aau?", {}, undefined, nepali))
      .toBe("Timi kahile ghar aaunchhau?")
    expect(salvageCopyedit("ma janchhu", "Ma pani janchhu.", {}, undefined, nepali)).toBe("Ma janchhu.")
  })

  test("leaves English transcripts to the usual rules", () => {
    expect(validateProseCleanup("send it to the ophis", "send it to the office").ok).toBe(false)
  })
})
