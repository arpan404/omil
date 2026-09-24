import OmilCore

enum TextDeliveryOutcome {
    case inserted(InsertionReceipt)
    case pasteSent
    case copiedForManualPaste
    case retained(String)
}

enum PasteAttempt {
    case sent
    case copied
    case unavailable
}

/// Chooses how a completed transcript reaches the field captured at recording start.
enum TextDelivery {
    static func attempt(
        text: String,
        precondition: SelectionPrecondition,
        sessionId: SessionID,
        sequence: Int,
        destination: any TextDestination,
        trusted: Bool,
        paste: (String) -> PasteAttempt
    ) -> TextDeliveryOutcome {
        guard trusted else {
            return .retained("Accessibility access is needed to insert into another app")
        }
        switch destination.revalidate(precondition: precondition) {
        case .stale(let reason):
            return .retained(reason)
        case .pasteOnly:
            return fallback(text: text, paste: paste)
        case .ok:
            do {
                let receipt = try destination.insert(
                    text: text, precondition: precondition,
                    sessionId: sessionId, sequence: sequence
                )
                return .inserted(receipt)
            } catch DeliveryError.destinationChanged(let reason) {
                return .retained(reason)
            } catch {
                return fallback(text: text, paste: paste)
            }
        }
    }

    private static func fallback(text: String, paste: (String) -> PasteAttempt) -> TextDeliveryOutcome {
        switch paste(text) {
        case .sent: return .pasteSent
        case .copied: return .copiedForManualPaste
        case .unavailable: return .retained("Couldn't preserve the clipboard. Transcript saved in Omil")
        }
    }
}
