import SwiftUI
import OmilCore

// MARK: - Omil main window (Wispr-style app shell)
//
// Sidebar navigation across the whole product: dictation, history,
// dictionary, and the owned inference core. The menu bar extra stays as the
// compact recorder + indicator.

enum MainSection: String, Hashable {
    case home, dictate, history, dictionary, models, help
}

struct MainWindowView: View {
    @ObservedObject var controller: DictationController
    @Environment(\.openSettings) private var openSettings
    @State private var section: MainSection? = .home

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section {
                    Label("Home", systemImage: "house").tag(MainSection.home)
                    Label("Dictate", systemImage: "mic.fill").tag(MainSection.dictate)
                    Label("History", systemImage: "clock").tag(MainSection.history)
                    Label("Dictionary", systemImage: "book").tag(MainSection.dictionary)
                    Label("Models", systemImage: "cpu").tag(MainSection.models)
                }
                Section {
                    Button { openSettings() } label: {
                        Label("Settings", systemImage: "gear")
                    }
                    .buttonStyle(.plain)
                    Label("Help", systemImage: "questionmark.circle").tag(MainSection.help)
                }
            }
            .navigationTitle("Omil")
            .listStyle(.sidebar)
        } detail: {
            switch section ?? .home {
            case .home: HomeView(controller: controller, goDictate: { section = .dictate })
            case .dictate: DictateView(controller: controller)
            case .history: HistoryView(controller: controller)
            case .dictionary: DictionaryView(controller: controller)
            case .models: ModelsView(controller: controller)
            case .help: HelpView(controller: controller)
            }
        }
        .navigationTitle(sectionTitle)
    }

    var sectionTitle: String {
        switch section ?? .home {
        case .home: return "Home"
        case .dictate: return "Dictate"
        case .history: return "History"
        case .dictionary: return "Dictionary"
        case .models: return "Models"
        case .help: return "Help"
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @ObservedObject var controller: DictationController
    var goDictate: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Hero: the one action that matters.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hold \(HotkeyManager.shared.pushToTalkName), speak, release.")
                        .font(.title2)
                    Text("Omil transcribes on your Mac, cleans up filler and self-corrections, and inserts the result where your cursor is.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Dictate now") {
                            goDictate()
                            controller.toggle()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(controller.phase == .preparing || controller.phase == .processing)
                        Button("How it works") { goDictate() }
                            .buttonStyle(.bordered)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(12)

                // Stats.
                HStack(spacing: 12) {
                    StatCard(title: "Words dictated", value: "\(controller.totalWords)")
                    StatCard(title: "Dictations", value: "\(controller.totalDictations)")
                    StatCard(title: "Day streak", value: "\(controller.dayStreak)")
                }

                // Recent.
                HStack {
                    Text("Recent")
                        .font(.headline)
                    Spacer()
                }
                if controller.history.isEmpty {
                    Text("Nothing yet — your dictations will appear here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.history.prefix(3)) { entry in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.cleaned)
                                    .lineLimit(2)
                                Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) • \(entry.wordCount) words")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Copy") {
                                NSPasteboard.general.declareTypes([.string], owner: nil)
                                NSPasteboard.general.setString(entry.cleaned, forType: .string)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(8)
                    }
                }
                Spacer()
            }
            .padding()
        }
    }
}

struct StatCard: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.largeTitle)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }
}

// MARK: - Help

struct HelpView: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        Form {
            Section("Troubleshooting") {
                Text("No text appears? Grant Accessibility (Settings → Permissions), then speak into a focused text field.")
                Text("Start fails? Install prerequisites under Models — the server needs its engines and weights.")
                Text("Wrong words? Open the dictation in History to compare raw and cleaned text.")
            }
            Section("Diagnostics") {
                Button("Copy diagnostics") {
                    NSPasteboard.general.declareTypes([.string], owner: nil)
                    NSPasteboard.general.setString(controller.diagnostics(), forType: .string)
                }
                Text("Paste it when reporting an issue. Contains no transcript content.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("About") {
                Text("Omil \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") — local-first dictation for Mac.")
            }
        }
        .padding()
    }
}

// MARK: - Dictate

struct DictateView: View {
    @ObservedObject var controller: DictationController
    @State private var tab = 0
    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Readiness banner: onboarding lives where the action is.
            if controller.micPermission != .granted {
                HStack {
                    Image(systemName: "mic.slash")
                    Text("Microphone access needed to record.")
                        .font(.callout)
                    Spacer()
                    Button("Grant access") { controller.requestMic() }
                }
                .padding(8)
                .background(Color.yellow.opacity(0.15))
                .cornerRadius(8)
            }

            HStack(spacing: 16) {
                RecordButton(controller: controller, onStart: { startTimer() }, onStop: { stopTimer() })
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(controller.phase == .recording ? Color.red : Color.gray)
                            .frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                        Text(statusLine)
                            .font(.headline)
                    }
                    Text(controller.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("offline • on-device")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(controller.backendDescription)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Picker("", selection: $tab) {
                Text("Draft").tag(0)
                Text("Raw").tag(1)
                Text("Cleaned").tag(2)
                Text("Diff").tag(3)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Result view")

            Group {
                switch tab {
                case 0:
                    Text(draftPlaceholder)
                        .foregroundStyle(.secondary)
                case 1:
                    Text(controller.lastRaw.isEmpty ? "No transcript yet — record something." : controller.lastRaw)
                case 2:
                    Text(controller.lastCleaned.isEmpty ? "No result yet." : controller.lastCleaned)
                default:
                    Text(controller.lastDiff.isEmpty ? "No diff yet." : controller.lastDiff)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .textSelection(.enabled)
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(8)

            if !controller.lastCleaned.isEmpty {
                HStack {
                    Button("Copy") { controller.copyLast() }
                    Button("Insert again") { controller.insertRetainedResult() }
                    Button("Undo") { controller.undoLast() }
                        .disabled(!controller.canUndo)
                    Spacer()
                    Text(controller.lastDeliveryMethod)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Start") { controller.start(); startTimer() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(!canStart)
                Button("Stop") { controller.stop(); stopTimer() }
                    .disabled(controller.phase != .recording)
                Button("Cancel") { controller.cancel(); stopTimer() }
                    .disabled(controller.phase != .recording && controller.phase != .processing)
                Spacer()
                Picker("Mode", selection: $controller.cleanupMode) {
                    Text("Clean").tag(CleanupMode.clean)
                    Text("Verbatim").tag(CleanupMode.verbatim)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .accessibilityLabel("Cleanup mode")
            }
        }
        .padding()
        .onDisappear { stopTimer() }
    }

    var canStart: Bool {
        controller.phase == .idle || controller.phase == .ready || controller.phase == .failed
    }

    var statusLine: String {
        switch controller.phase {
        case .idle: return "Ready"
        case .preparing: return "Preparing…"
        case .recording: return "Recording… \(formatElapsed(elapsed))"
        case .processing: return "Finalizing…"
        case .ready: return "Result ready"
        case .failed: return "Attention needed"
        }
    }

    var draftPlaceholder: String {
        if controller.phase == .recording {
            return controller.draftText.isEmpty ? "Listening…" : controller.draftText
        }
        return "Focus a text field, press Start (or hold Right Option), and speak naturally."
    }

    func startTimer() {
        stopTimer()
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            elapsed += 0.5
        }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func formatElapsed(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

// MARK: - Big record button

struct RecordButton: View {
    @ObservedObject var controller: DictationController
    var onStart: () -> Void = {}
    var onStop: () -> Void = {}

    var body: some View {
        Button {
            if controller.phase == .recording {
                controller.stop()
                onStop()
            } else {
                controller.start()
                onStart()
            }
        } label: {
            Image(systemName: controller.phase == .recording ? "stop.fill" : "mic.fill")
                .font(.system(size: 22))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(controller.phase == .recording ? Color.red : Color.accentColor)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(controller.phase == .preparing || controller.phase == .processing)
        .accessibilityLabel(controller.phase == .recording ? "Stop recording" : "Start recording")
        .accessibilityHint("Toggles the current dictation session")
    }
}

// MARK: - Dictionary

struct DictionaryView: View {
    @ObservedObject var controller: DictationController
    @State private var spoken = ""
    @State private var written = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Confirmed substitutions only — entries apply exactly as written, never as free rewrites.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                TextField("Spoken", text: $spoken)
                TextField("Written", text: $written)
                Button("Add") {
                    guard !spoken.isEmpty, !written.isEmpty else { return }
                    controller.confirmDictionary(spoken: spoken, written: written)
                    spoken = ""
                    written = ""
                }
                .keyboardShortcut(.return, modifiers: [.command])
            }
            if controller.dictionaryEntries.isEmpty {
                ContentUnavailableView(
                    "No entries",
                    systemImage: "book",
                    description: Text("Add names, acronyms, and product terms you dictate often.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(Array(controller.dictionaryEntries.keys.sorted()), id: \.self) { key in
                    HStack {
                        Text(key)
                        Spacer()
                        Text(controller.dictionaryEntries[key] ?? "")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            Spacer()
        }
        .padding()
    }
}

// MARK: - Models (owned inference core)

struct ModelsView: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox("Engine") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Status: \(controller.server.status.label)")
                        HStack {
                            Button("Restart server") { controller.server.restart() }
                            Button("Reveal server log") {
                                NSWorkspace.shared.activateFileViewerSelecting([ServerAssets.logURL])
                            }
                        }
                    }
                    .padding(4)
                }

                GroupBox("Prerequisites") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("One install: sidecar engines + the selected Whisper and Qwen weights. No Homebrew needed.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Picker("Whisper model", selection: $controller.whisperFile) {
                            ForEach(ServerAssets.whisperOptions, id: \.id) { opt in
                                Text("\(opt.displayName) (~\(opt.approxMB) MB)").tag(opt.id)
                            }
                        }
                        .onChange(of: controller.whisperFile) { controller.selectModels() }
                        Picker("Rewrite model", selection: $controller.llmFile) {
                            ForEach(ServerAssets.llmOptions, id: \.id) { opt in
                                Text("\(opt.displayName) (~\(opt.approxMB) MB)").tag(opt.id)
                            }
                        }
                        .onChange(of: controller.llmFile) { controller.selectModels() }
                        if !controller.serverOpNote.isEmpty {
                            Text(controller.serverOpNote)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(controller.assets.requiredPins, id: \.id) { pin in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(pin.displayName).font(.body)
                                    Text(pin.version).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                assetStateView(controller.assets.states[pin.id] ?? .missing)
                            }
                        }
                        HStack {
                            Button(controller.assets.allReady ? "Prerequisites installed" : "Install prerequisites") {
                                controller.assets.installPrerequisites {
                                    Task { @MainActor in controller.adoptServerToken() }
                                }
                            }
                            .disabled(controller.assets.isInstalling || controller.assets.allReady)
                            Button("Recheck") { controller.assets.refreshState() }
                        }
                    }
                    .padding(4)
                }

                GroupBox("Rewrite prompt") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(controller.promptCustom ? "Custom prompt active." : "Using the default prompt.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $controller.promptText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 160)
                            .border(Color.secondary.opacity(0.3))
                        HStack {
                            Button("Load current") { controller.loadPrompt() }
                            Button("Save custom prompt") { controller.savePrompt() }
                            Button("Reset to default") { controller.resetPrompt() }
                        }
                    }
                    .padding(4)
                }

                GroupBox("Connection") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("This Mac connects to its own server automatically. iPhone/iPad use the Mac's LAN address + the token below.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        HStack {
                            TextField("Host (Mac IP)", text: $controller.serverConfig.host)
                            TextField("Port", value: $controller.serverConfig.port, format: .number)
                                .frame(width: 80)
                            Button("Save & test") { controller.saveServerConfig() }
                        }
                        HStack {
                            Text("Token: managed automatically")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(controller.serverHealth)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Toggle("Qwen cleanup via server", isOn: Binding(
                            get: { controller.serverCleanupEnabled },
                            set: { controller.serverCleanupEnabled = $0; controller.saveServerConfig() }
                        ))
                        if !controller.serverNote.isEmpty {
                            Text(controller.serverNote)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(4)
                }
            }
            .padding()
        }
        .onAppear { controller.loadPrompt() }
    }
}
