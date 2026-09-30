import AppIntents

// MARK: - App Intents
//
// Exposes dictation to Shortcuts, Spotlight, and Siri. Intents run in the app
// process against the shared controller, so they behave exactly like the
// keyboard shortcuts and the menu bar.

struct StartDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Dictation"
    static let description = IntentDescription("Starts listening and types what you say into the app you're using.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        let controller = AppContext.controller
        if controller.phase != .recording && controller.phase != .preparing {
            controller.start(source: .shortcut)
        }
        return .result()
    }
}

struct StopDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Dictation"
    static let description = IntentDescription("Stops listening and inserts the transcript.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        if AppContext.controller.phase == .recording { AppContext.controller.stop() }
        return .result()
    }
}

struct ToggleDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Dictation"
    static let description = IntentDescription("Starts dictation, or stops it if Omil is already listening.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        AppContext.controller.toggle(source: .shortcut)
        return .result()
    }
}

struct CancelDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Cancel Dictation"
    static let description = IntentDescription("Stops listening without inserting anything.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        AppContext.controller.cancel()
        return .result()
    }
}

struct GetLastTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Last Transcript"
    static let description = IntentDescription("Returns the most recent cleaned-up transcript so other actions can use it.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = AppContext.controller.lastCleaned
        return .result(value: text, dialog: IntentDialog(stringLiteral: text.isEmpty ? "There's no transcript yet." : text))
    }
}

struct CopyLastTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Last Transcript"
    static let description = IntentDescription("Copies the most recent transcript to the clipboard.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        AppContext.controller.copyLast()
        return .result()
    }
}

struct OpenHistoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Dictation History"
    static let description = IntentDescription("Opens Omil to your past transcripts.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppContext.appDelegate?.showMainWindow(section: .history)
        return .result()
    }
}

struct OmilShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleDictationIntent(),
            phrases: ["Dictate with \(.applicationName)", "Start \(.applicationName)", "Toggle \(.applicationName) dictation"],
            shortTitle: "Dictate",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: GetLastTranscriptIntent(),
            phrases: ["Get my last \(.applicationName) transcript", "What did I dictate in \(.applicationName)"],
            shortTitle: "Last Transcript",
            systemImageName: "text.quote"
        )
        AppShortcut(
            intent: CopyLastTranscriptIntent(),
            phrases: ["Copy my last \(.applicationName) transcript"],
            shortTitle: "Copy Transcript",
            systemImageName: "doc.on.doc"
        )
        AppShortcut(
            intent: OpenHistoryIntent(),
            phrases: ["Open \(.applicationName) history"],
            shortTitle: "History",
            systemImageName: "clock"
        )
    }
}
