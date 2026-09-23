/// A per-device balance between picking up quiet speech and rejecting noise.
/// Only Omil server transcription uses this setting.
public enum SpeechSensitivity: String, CaseIterable, Codable, Sendable, Identifiable {
    case strict
    case balanced
    case distant

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .strict: "Filter more noise"
        case .balanced: "Balanced"
        case .distant: "Distant voice"
        }
    }

    public var detail: String {
        switch self {
        case .strict: "Ignores more background sound, but may miss quiet words."
        case .balanced: "Works well when you speak near the microphone."
        case .distant: "Picks up quieter or slower speech, with more chance of hearing noise."
        }
    }
}
