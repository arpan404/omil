import SwiftUI
import OmilCore

@main
struct OmilIOSApp: App {
    @StateObject private var coordinator = SessionCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView(coordinator: coordinator)
        }
    }
}

struct ContentView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @State private var tab = 0
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Recording state: always visible.
                HStack {
                    Circle()
                        .fill(coordinator.phase == .recording ? Color.red : Color.gray)
                        .frame(width: 14, height: 14)
                        .accessibilityLabel(coordinator.phase == .recording ? "Recording" : "Not recording")
                    Text(title)
                        .font(.title2.bold())
                    Spacer()
                    Text(coordinator.backendPreference == .omilServer ? "your Mac" : "on-device")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if coordinator.phase == .recording {
                    Text(coordinator.draftText.isEmpty ? "Listening…" : coordinator.draftText)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                        .accessibilityLabel("Live draft transcript")
                }

                // Explicit start / stop / cancel.
                HStack(spacing: 12) {
                    Button {
                        coordinator.start()
                    } label: {
                        Label("Record", systemImage: "mic.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(coordinator.phase == .recording || coordinator.phase == .processing || coordinator.phase == .preparing)
                    .accessibilityHint("Starts a dictation session")

                    Button {
                        coordinator.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(coordinator.phase != .recording)
                    .accessibilityHint("Stops recording and finalizes the result")

                    Button("Cancel") { coordinator.cancel() }
                        .buttonStyle(.bordered)
                        .disabled(coordinator.phase != .recording && coordinator.phase != .processing)
                }

                Picker("View", selection: $tab) {
                    Text("Cleaned").tag(0)
                    Text("Raw").tag(1)
                    Text("Diff").tag(2)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Result view")

                ScrollView {
                    Text(viewText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding()
                }
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)

                Text(coordinator.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Delivery: keyboard handoff + copy/share fallback.
                VStack(spacing: 8) {
                    Text(coordinator.keyboardHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button {
                            UIPasteboard.general.string = coordinator.lastCleaned
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .disabled(coordinator.lastCleaned.isEmpty)

                        Button {
                            showShare = true
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                        .disabled(coordinator.lastCleaned.isEmpty)

                        NavigationLink {
                            SettingsView(coordinator: coordinator)
                        } label: {
                            Label("Settings", systemImage: "gear")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Omil Dictation")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showShare) {
                ShareSheet(text: coordinator.lastCleaned)
            }
            .task {
                await coordinator.refreshStatus()
                coordinator.refreshKeyboardHint()
            }
        }
    }

    var title: String {
        switch coordinator.phase {
        case .idle: return "Ready"
        case .preparing: return "Preparing…"
        case .recording: return "Recording…"
        case .processing: return "Finalizing…"
        case .ready: return "Result ready"
        case .failed: return "Attention needed"
        }
    }

    var viewText: String {
        switch tab {
        case 1: return coordinator.lastRaw.isEmpty ? "(no transcript yet)" : coordinator.lastRaw
        case 2: return coordinator.lastDiff.isEmpty ? "(no diff yet)" : coordinator.lastDiff
        default: return coordinator.lastCleaned.isEmpty ? "Tap Record, speak naturally, then Stop." : coordinator.lastCleaned
        }
    }
}

struct SettingsView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @State private var spoken = ""
    @State private var written = ""

    var body: some View {
        Form {
            Section("Cleanup (independent of transcription)") {
                Picker("Mode", selection: Binding(
                    get: { coordinator.cleanupMode },
                    set: { coordinator.setMode($0) }
                )) {
                    Text("Clean (default)").tag(CleanupMode.clean)
                    Text("Verbatim").tag(CleanupMode.verbatim)
                }
            }
            Section("Speech backend") {
                Picker("Backend", selection: $coordinator.backendPreference) {
                    Text("Omil server (your Mac)").tag(BackendChoice.omilServer)
                    Text("Automatic (on-device)").tag(BackendChoice.automatic)
                    Text("System speech").tag(BackendChoice.appleSpeech)
                    Text("Legacy on-device").tag(BackendChoice.legacySFSpeech)
                }
                .onChange(of: coordinator.backendPreference) { coordinator.saveServerConfig() }
                Text(coordinator.backendDescription).font(.caption)
                Text("Assets: \(coordinator.assetState)").font(.caption)
                Button("Refresh") {
                    Task { await coordinator.refreshStatus() }
                }
            }
            Section("Omil server (your Mac)") {
                Text("In the Omil Mac app, open Engine and turn on Share on local network. Copy the host, port, and token shown there.")
                    .font(.caption)
                Picker("Speech sensitivity", selection: $coordinator.speechSensitivity) {
                    ForEach(SpeechSensitivity.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                Text(coordinator.speechSensitivity.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Mac host/IP", text: $coordinator.serverConfig.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    TextField("Port", value: $coordinator.serverConfig.port, format: .number)
                        .keyboardType(.numberPad)
                    SecureField("Token", text: $coordinator.serverConfig.token)
                }
                Button("Save & test server") { coordinator.saveServerConfig() }
                Text(coordinator.serverHealth).font(.caption)
                Toggle("Qwen cleanup via server", isOn: Binding(
                    get: { coordinator.serverCleanupEnabled },
                    set: { coordinator.serverCleanupEnabled = $0; coordinator.saveServerConfig() }
                ))
            }
            Section("Advanced") {
                DisclosureGroup("Cleanup system prompt") {
                    Text("Sent with cleanup requests from this iPhone. The server prompt is used until you save an override.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $coordinator.cleanupPromptText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 180)
                        .accessibilityLabel("Cleanup system prompt")
                    HStack {
                        Button("Use server prompt") { coordinator.resetCleanupPrompt() }
                            .disabled(!coordinator.cleanupPromptCustom)
                        Spacer()
                        Button("Save prompt") { coordinator.saveCleanupPrompt() }
                            .disabled(coordinator.cleanupPromptText.trimmingCharacters(in: .whitespacesAndNewlines).count < 50 || coordinator.cleanupPromptText.count > 50_000)
                    }
                }
            }
            Section("Personal dictionary") {
                HStack {
                    TextField("Spoken", text: $spoken)
                    TextField("Written", text: $written)
                    Button("Add") {
                        guard !spoken.isEmpty, !written.isEmpty else { return }
                        coordinator.confirmDictionary(spoken: spoken, written: written)
                        spoken = ""
                        written = ""
                    }
                }
                ForEach(Array(coordinator.dictionaryEntries.keys.sorted()), id: \.self) { key in
                    HStack {
                        Text(key)
                        Spacer()
                        Text(coordinator.dictionaryEntries[key] ?? "").foregroundStyle(.secondary)
                    }
                }
            }
            Section("Keyboard") {
                Text("Enable the Omil keyboard in Settings → General → Keyboard → Keyboards, then grant Full Access so it can read completed results from the shared app group.")
                    .font(.caption)
            }
            Section("Privacy") {
                Text("With the Omil server selected, audio and preferences travel only to your Mac over the local network. Omil does not require an account.")
                    .font(.caption)
            }
        }
        .task { await coordinator.loadCleanupPrompt() }
        .navigationTitle("Settings")
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    var text: String
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
