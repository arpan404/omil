import Foundation

// MARK: - BackendSelector
//
// One recommended configuration + explicit override. Transcription choice is
// independent of cleanup mode: a faster/different engine never disables
// correction behavior.

public enum BackendChoice: String, Sendable, Codable {
    case automatic
    case omilServer
    case appleSpeech
    case legacySFSpeech
}

public enum ResolvedBackend: Sendable {
    case omilServer
    case appleSpeech
    case legacySFSpeech
    case unavailable(reason: String)
}

public struct BackendSelector: Sendable {
    public init() {}

    public func resolve(status: AppleSpeechStatus, preference: BackendChoice) -> ResolvedBackend {
        switch preference {
        case .omilServer:
            // Reachability is checked at prepare()/start with a clear error;
            // resolving is unconditional so the server stays the default.
            return .omilServer
        case .appleSpeech:
            guard status.speechTranscriberAvailable else {
                return .unavailable(reason: "Apple SpeechTranscriber unavailable: \(status.detail)")
            }
            return .appleSpeech
        case .legacySFSpeech:
            guard status.sfOnDeviceAvailable else {
                return .unavailable(reason: "SFSpeech on-device unavailable: \(status.detail)")
            }
            return .legacySFSpeech
        case .automatic:
            if status.speechTranscriberAvailable { return .appleSpeech }
            if status.sfOnDeviceAvailable { return .legacySFSpeech }
            return .unavailable(reason: "no on-device backend: \(status.detail)")
        }
    }

    /// Display name + asset/download disclosure for settings.
    public func describe(status: AppleSpeechStatus, resolved: ResolvedBackend) -> String {
        switch resolved {
        case .omilServer:
            return "Omil server (speech and cleanup models on your Mac)"
        case .appleSpeech:
            return "System (Apple Speech, on-device, system-managed assets)"
        case .legacySFSpeech:
            return "System legacy (SFSpeech on-device, no download)"
        case .unavailable(let r):
            return "Unavailable — \(r)"
        }
    }
}
