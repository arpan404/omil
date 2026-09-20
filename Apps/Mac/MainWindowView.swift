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

/// Root content of the imperative AppKit main window: onboarding until
/// complete, then the Hub. (A plain ViewBuilder conditional — always works,
// unlike the SwiftUI Window scene which never materialized.)
struct RootView: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        Group {
            if controller.onboarded {
                MainWindowView(controller: controller)
            } else {
                OnboardingView(controller: controller)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
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
                        .fontDesign(.rounded)
                        .fontWeight(.semibold)
                    Text("Omil transcribes on your Mac, cleans up filler and self-corrections, and inserts the result where your cursor is.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Dictate now") {
                            goDictate()
                            controller.toggle()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(controller.phase == .preparing || controller.phase == .processing)
                        Button("How it works") { goDictate() }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                    }
                    .padding(.top, 4)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.22), Color.purple.opacity(0.14)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .cornerRadius(16)

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
                            .controlSize(.small)
                        }
                        .padding(10)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(12)
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
                .fontDesign(.rounded)
                .fontWeight(.bold)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(14)
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
                        RecordingDot(active: controller.phase == .recording)
                        Text(statusLine)
                            .font(.headline)
                            .fontDesign(.rounded)
                    }
                    Text(controller.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("on-device inference")
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
        .onChange(of: controller.phase) { _, phase in
            // A15: keep the timer honest when recording stops anywhere
            // (hotkey release, pill button, toggle) — not just here.
            if phase == .recording {
                if timer == nil { startTimer() }
            } else {
                stopTimer()
            }
        }
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

// MARK: - Shared bits

/// Pulsing recording indicator used across Dictate, menu-adjacent views.
struct RecordingDot: View {
    var active: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(active ? Color.red : Color.gray)
            .frame(width: 10, height: 10)
            .scaleEffect(active && pulse ? 1.35 : 1.0)
            .opacity(active && pulse ? 0.65 : 1.0)
            .animation(active ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: pulse)
            .accessibilityLabel(active ? "Recording" : "Not recording")
            .onAppear { pulse = active }
            .onChange(of: active) { _, on in pulse = on }
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
        .shadow(color: controller.phase == .recording ? .red.opacity(0.4) : .accentColor.opacity(0.35), radius: 10)
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

private struct ModelOption {
    var file: String
    var displayName: String
    var approxMB: Int
}

private let whisperModelOptions: [ModelOption] = [
    ModelOption(file: "ggml-tiny.bin", displayName: "Whisper tiny — fastest", approxMB: 77),
    ModelOption(file: "ggml-base.bin", displayName: "Whisper base — fast", approxMB: 148),
    ModelOption(file: "ggml-small.bin", displayName: "Whisper small — balanced", approxMB: 488),
    ModelOption(file: "ggml-medium.bin", displayName: "Whisper medium — accurate", approxMB: 1570),
    ModelOption(file: "ggml-large-v3-turbo.bin", displayName: "Whisper large-v3-turbo — recommended", approxMB: 1624),
    ModelOption(file: "ggml-large-v3.bin", displayName: "Whisper large-v3 — most accurate", approxMB: 3110),
]

private let rewriteModelOptions: [ModelOption] = [
    ModelOption(file: "Qwen3-0.6B-Q4_K_M.gguf", displayName: "Qwen3 0.6B — tiny, fast", approxMB: 397),
    ModelOption(file: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf", displayName: "Qwen3 4B — recommended", approxMB: 2497),
    ModelOption(file: "Qwen3-8B-Q4_K_M.gguf", displayName: "Qwen3 8B — best quality, 8GB+ headroom", approxMB: 5028),
]

/// Shared card chrome for the Hub: icon title, rounded surface.
struct OmilCard<Content: View>: View {
    var title: String
    var icon: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
                .fontDesign(.rounded)
                .foregroundStyle(.primary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(14)
    }
}

struct ModelsView: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                OmilCard(title: "Connection", icon: "network") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(controller.serverHealth.lowercased().contains("unreach") ? Color.orange : Color.green)
                                .frame(width: 8, height: 8)
                            Text(controller.serverHealth)
                                .font(.callout)
                        }
                        Text("Run the inference server separately (`cd server && bun src/main.ts`), then point this app at it. Missing weights download server-side on first use.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            TextField("Host", text: $controller.serverConfig.host)
                            TextField("Port", value: $controller.serverConfig.port, format: .number)
                                .frame(width: 80)
                        }
                        SecureField("Server token", text: $controller.serverConfig.token)
                        HStack {
                            Button("Save & test") { controller.saveServerConfig() }
                            Spacer()
                            Toggle("Qwen cleanup", isOn: Binding(
                                get: { controller.serverCleanupEnabled },
                                set: { controller.serverCleanupEnabled = $0; controller.saveServerConfig() }
                            ))
                            .toggleStyle(.switch)
                        }
                        if !controller.serverNote.isEmpty {
                            Text(controller.serverNote)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                OmilCard(title: "Speech model", icon: "waveform") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Whisper model", selection: $controller.whisperFile) {
                            ForEach(whisperModelOptions, id: \.file) { opt in
                                Text("\(opt.displayName) (~\(opt.approxMB) MB)").tag(opt.file)
                            }
                        }
                        .onChange(of: controller.whisperFile) { controller.selectModels() }
                        modelRows(kind: "whisper")
                        if !controller.serverOpNote.isEmpty {
                            Text(controller.serverOpNote)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                OmilCard(title: "Rewrite model", icon: "sparkles") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Rewrite model", selection: $controller.llmFile) {
                            ForEach(rewriteModelOptions, id: \.file) { opt in
                                Text("\(opt.displayName) (~\(opt.approxMB) MB)").tag(opt.file)
                            }
                        }
                        .onChange(of: controller.llmFile) { controller.selectModels() }
                        modelRows(kind: "llm")
                    }
                }

                OmilCard(title: "Rewrite prompt", icon: "text.quote") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(controller.promptCustom ? "Custom prompt active." : "Using the default prompt.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $controller.promptText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 150)
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                        HStack {
                            Button("Load current") { controller.loadPrompt() }
                            Button("Save custom prompt") { controller.savePrompt() }
                            Button("Reset to default") { controller.resetPrompt() }
                        }
                    }
                }
            }
            .padding()
        }
        .onAppear {
            controller.loadPrompt()
            Task { await controller.fetchServerModels() }
        }
    }

    @ViewBuilder
    func modelRows(kind: String) -> some View {
        ServerModelRows(rows: controller.serverModels.filter { $0.kind == kind })
    }
}

struct ServerModelRows: View {
    var rows: [DictationController.ServerModelInfo]

    var body: some View {
        if rows.isEmpty {
            Text("Model list unavailable — is the server running?")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(rows) { m in
                HStack {
                    Image(systemName: m.selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(m.selected ? Color.green : Color.secondary)
                    VStack(alignment: .leading) {
                        Text(m.id).font(.body)
                        Text(m.description).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(m.downloaded ? "downloaded" : "missing")
                        .font(.caption)
                        .foregroundStyle(m.downloaded ? Color.secondary : Color.orange)
                }
            }
        }
    }
}
