import SwiftUI
import OmilCore

// MARK: - Omil Mac app (menu bar agent)

@main
struct OmilMacApp: App {
    @StateObject private var controller = DictationController()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(controller: controller)
        } label: {
            Label("Omil", systemImage: controller.phase == .recording ? "mic.fill" : "mic")
        }
        .menuBarExtraStyle(.window)

        Window("Omil Recorder", id: "recorder") {
            RecorderView(controller: controller)
                .frame(minWidth: 420, minHeight: 300)
        }
        .windowResizability(.contentSize)

        Window("Omil History", id: "history") {
            HistoryView(controller: controller)
                .frame(minWidth: 560, minHeight: 400)
        }

        Settings {
            SettingsView(controller: controller)
                .frame(minWidth: 480, minHeight: 420)
        }
    }
}

// MARK: - Menu bar

struct MenuBarView: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(controller.phase == .recording ? Color.red : Color.gray)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text(statusTitle)
                    .font(.headline)
            }
            Text(controller.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            Divider()

            HStack {
                Button(controller.phase == .recording ? "Stop" : "Start") {
                    controller.toggle()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(controller.phase == .preparing || controller.phase == .processing)
                Button("Cancel") { controller.cancel() }
                    .disabled(controller.phase != .recording && controller.phase != .processing)
                    .keyboardShortcut(".", modifiers: [.command])
            }

            if controller.phase == .recording {
                Text("Draft: \(controller.draftText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !controller.lastCleaned.isEmpty {
                Divider()
                Text("Result")
                    .font(.headline)
                Text(controller.lastCleaned)
                    .font(.body)
                    .textSelection(.enabled)
                HStack {
                    Button("Copy") { controller.copyLast() }
                    Button("Insert again") { controller.insertRetainedResult() }
                    Button("Undo") { controller.undoLast() }
                        .disabled(controller.lastReceipt == nil)
                }
            }

            Divider()
            HStack {
                Picker("Mode", selection: $controller.cleanupMode) {
                    Text("Clean").tag(CleanupMode.clean)
                    Text("Verbatim").tag(CleanupMode.verbatim)
                }
                .pickerStyle(.segmented)
            }
            .accessibilityLabel("Cleanup mode")

            Text("Backend: \(controller.backendDescription)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Local/offline after assets installed. No account.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 360)
    }

    var statusTitle: String {
        switch controller.phase {
        case .idle: return "Omil — idle"
        case .preparing: return "Omil — preparing"
        case .recording: return "Omil — recording"
        case .processing: return "Omil — finalizing"
        case .ready: return "Omil — result ready"
        case .failed: return "Omil — attention needed"
        }
    }
}

// MARK: - Recorder window

struct RecorderView: View {
    @ObservedObject var controller: DictationController
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(controller.phase == .recording ? Color.red : Color.gray)
                    .frame(width: 12, height: 12)
                    .accessibilityLabel(controller.phase == .recording ? "Recording" : "Not recording")
                Text(controller.phase == .recording ? "Recording…" : "Omil Dictation")
                    .font(.title2)
                Spacer()
                Text("offline • on-device")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    Text(controller.phase == .recording ? controller.draftText : "Hold Right Option (or press Start) and speak.")
                        .foregroundStyle(.secondary)
                case 1:
                    Text(controller.lastRaw.isEmpty ? "(no transcript yet)" : controller.lastRaw)
                case 2:
                    Text(controller.lastCleaned.isEmpty ? "(no result yet)" : controller.lastCleaned)
                default:
                    Text(controller.lastDiff.isEmpty ? "(no diff yet)" : controller.lastDiff)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .textSelection(.enabled)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(8)

            HStack {
                Button("Start") { controller.start() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(controller.phase == .recording || controller.phase == .processing || controller.phase == .preparing)
                Button("Stop") { controller.stop() }
                    .disabled(controller.phase != .recording)
                Button("Cancel") { controller.cancel() }
                    .disabled(controller.phase != .recording && controller.phase != .processing)
                Spacer()
                Button("Copy") { controller.copyLast() }
                    .disabled(controller.lastCleaned.isEmpty)
                Button("Undo") { controller.undoLast() }
                    .disabled(controller.lastReceipt == nil)
            }
            Text(controller.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

// MARK: - History

struct HistoryView: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        List(controller.history) { entry in
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.cleaned)
                    .font(.body)
                    .textSelection(.enabled)
                Text("Raw: \(entry.raw)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("\(entry.date.formatted()) • \(entry.backend)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("History (kept on this Mac)")
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var controller: DictationController
    @State private var spoken = ""
    @State private var written = ""

    var body: some View {
        TabView {
            Form {
                Picker("Cleanup mode", selection: $controller.cleanupMode) {
                    Text("Clean (default)").tag(CleanupMode.clean)
                    Text("Verbatim").tag(CleanupMode.verbatim)
                }
                Picker("Transcription", selection: $controller.backendPreference) {
                    Text("Automatic (recommended)").tag(BackendChoice.automatic)
                    Text("System speech").tag(BackendChoice.appleSpeech)
                    Text("Legacy on-device").tag(BackendChoice.legacySFSpeech)
                }
                Text("Backend: \(controller.backendDescription)")
                    .font(.caption)
                Text("Assets: \(controller.assetState)")
                    .font(.caption)
                Button("Refresh model status") {
                    Task { await controller.refreshBackendStatus() }
                }
                Text("Changing transcription never changes cleanup behavior.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .tabItem { Label("General", systemImage: "gear") }
            .padding()

            Form {
                Text("Push-to-talk: hold Right Option. Toggle: Ctrl+Option+O.")
                Text("Microphone: \(controller.axTrusted ? "Accessibility granted" : "grant Accessibility for direct insertion")")
                if !controller.axTrusted {
                    Button("Open Accessibility settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
                Button("Open Microphone settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }
            }
            .tabItem { Label("Permissions", systemImage: "mic.badge.plus") }
            .padding()

            VStack(alignment: .leading) {
                Text("Personal dictionary (confirmed substitutions only)")
                    .font(.headline)
                HStack {
                    TextField("Spoken", text: $spoken)
                    TextField("Written", text: $written)
                    Button("Add") {
                        guard !spoken.isEmpty, !written.isEmpty else { return }
                        controller.confirmDictionary(spoken: spoken, written: written)
                        spoken = ""
                        written = ""
                    }
                }
                List(Array(controller.dictionaryEntries.keys.sorted()), id: \.self) { key in
                    HStack {
                        Text(key)
                        Spacer()
                        Text(controller.dictionaryEntries[key] ?? "")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .tabItem { Label("Dictionary", systemImage: "book") }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 420)
    }
}
