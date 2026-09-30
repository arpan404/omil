import Foundation
import OmilCore

/// Readable engine state derived from the coordinator's status strings.
extension SessionCoordinator {
    enum MacConnection: Equatable {
        case notConfigured, tokenRejected, checking, ready, preparing, needsAttention, unreachable
    }

    var macConnection: MacConnection {
        guard serverConfig.isConfigured else { return .notConfigured }
        let health = serverHealth
        if health.hasPrefix("Token rejected") { return .tokenRejected }
        if health == "Unknown" || health.hasPrefix("Checking") { return .checking }
        if health.contains(" · ") {
            if health.contains("missing") { return .needsAttention }
            if health.contains("downloading") { return .preparing }
            return .ready
        }
        return .unreachable
    }

    /// Dictation can't work until the user pairs with their Mac.
    var needsMacSetup: Bool {
        backendPreference == .omilServer &&
            (macConnection == .notConfigured || macConnection == .tokenRejected)
    }

    struct EngineNotice: Equatable {
        let title: String
        let detail: String
    }

    /// A notice only when the engine is not ready; nil when it is (or while checking).
    var engineNotice: EngineNotice? {
        if backendPreference == .omilServer {
            switch macConnection {
            case .preparing:
                return EngineNotice(title: "Your Mac Is Getting Ready",
                                    detail: "Speech models are still downloading on your Mac.")
            case .needsAttention:
                return EngineNotice(title: "Your Mac Needs Attention",
                                    detail: "Open Omil on your Mac to finish setting up its speech engine.")
            case .unreachable:
                return EngineNotice(title: "Can't Reach Your Mac",
                                    detail: "Make sure Omil is open on your Mac and both devices are on the same network.")
            case .notConfigured, .tokenRejected, .checking, .ready:
                return nil
            }
        }
        let state = assetState
        if state.hasPrefix("Ready") || state == "Unknown" || state.hasPrefix("Checking") { return nil }
        return EngineNotice(title: "Speech Isn't Available", detail: state)
    }

    var macConnectionTitle: String {
        switch macConnection {
        case .notConfigured: return "Not Connected"
        case .tokenRejected: return "Pair Again"
        case .checking: return "Checking…"
        case .ready: return "Connected"
        case .preparing: return "Getting Ready"
        case .needsAttention: return "Needs Attention"
        case .unreachable: return "Unreachable"
        }
    }
}
