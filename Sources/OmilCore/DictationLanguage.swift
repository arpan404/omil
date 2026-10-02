/// The language Omil server transcription listens for and writes in.
public enum DictationLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case english = "en"
    /// Nepali mixed with English, written in Latin letters the way Nepali
    /// speakers type in chats ("ma bholi office janchhu").
    case nepaliRoman = "ne-Latn"
    case nepali = "ne"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .english: "English"
        case .nepaliRoman: "Nepali (Roman)"
        case .nepali: "Nepali (Devanagari)"
        }
    }

    public var detail: String {
        switch self {
        case .english: "Transcribes English."
        case .nepaliRoman: "Nepali and English, typed in Roman letters, like \"ma bholi office janchhu\"."
        case .nepali: "Nepali written in Devanagari."
        }
    }
}
