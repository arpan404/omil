import SwiftUI
import OmilCore

// MARK: - Omil Mac app (menu bar agent, owns the inference server)

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var controller: DictationController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("Omil launched")
        controller?.startup()
        // Agent apps (LSUIElement) don't activate on their own — bring the
        // main window forward explicitly so first launch shows the app.
        // Retry: the SwiftUI scene may not exist yet on first tick.
        NSApp.activate(ignoringOtherApps: true)
        attemptOrderFront(tries: 20)
    }

    private func attemptOrderFront(tries: Int) {
        if orderMainWindowFront() { return }
        guard tries > 0 else {
            NSLog("Omil: main window never appeared")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.attemptOrderFront(tries: tries - 1)
        }
    }

    /// openWindow is unreliable from MenuBarExtra content — order the
    /// SwiftUI Window scene's NSWindow forward directly.
    /// - Returns: whether a main window was found.
    @discardableResult
    func openMainWindow() -> Bool {
        NSLog("Omil: Open Omil pressed")
        return orderMainWindowFront()
    }

    @discardableResult
    private func orderMainWindowFront() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.title == "Omil" && $0.canBecomeMain }) {
            w.makeKeyAndOrderFront(nil)
            NSLog("Omil: main window front")
            return true
        } else if let w = NSApp.windows.first(where: { $0.title == "Omil" }) {
            w.orderFrontRegardless()
            NSLog("Omil: main window front (regardless)")
            return true
        } else {
            NSLog("Omil: main window not found among %d windows", NSApp.windows.count)
            return false
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdownServer()
    }
}

@main
struct OmilMacApp: App {
    @StateObject private var controller = DictationController()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // Wire terminate-time server shutdown (both wrappers exist by now).
        _delegate.wrappedValue.controller = _controller.wrappedValue
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(controller: controller)
        } label: {
            Label("Omil", systemImage: controller.phase == .recording ? "mic.fill" : "mic")
        }
        .menuBarExtraStyle(.window)

        Window("Omil", id: "main") {
            MainWindowView(controller: controller)
                .frame(minWidth: 760, minHeight: 520)
        }
        .windowResizability(.contentSize)

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
                        .disabled(!controller.canUndo)
                }
                Text(controller.lastDeliveryMethod)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
            if !controller.assets.allReady {
                Text("Prerequisites missing — the server has nothing to run with yet.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button(controller.assets.isInstalling ? "Installing… (see Models tab for progress)" : "Install prerequisites (~4.3 GB)") {
                    controller.assets.installPrerequisites {
                        Task { @MainActor in controller.adoptServerToken() }
                    }
                }
                .disabled(controller.assets.isInstalling || controller.assets.allReady)
            }
            Text("Engine: \(controller.server.status.label)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Local/offline after assets installed. No account.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button("Open Omil") {
                (NSApp.delegate as? AppDelegate)?.openMainWindow()
            }
            Button("Copy diagnostics") {
                NSPasteboard.general.declareTypes([.string], owner: nil)
                NSPasteboard.general.setString(controller.diagnostics(), forType: .string)
            }
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

// MARK: - History

struct HistoryView: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        NavigationStack {
            VStack {
                if controller.history.isEmpty {
                    ContentUnavailableView(
                        "No history",
                        systemImage: "mic.slash",
                        description: Text("Dictation results appear here when history is on. Raw audio is never stored.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
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
                }
            }
            .navigationTitle("History (kept on this Mac)")
            .toolbar {
                Toggle("Keep history", isOn: Binding(
                    get: { controller.historyEnabled },
                    set: { controller.setHistoryEnabled($0) }
                ))
                Button("Clear") { controller.clearHistory() }
                    .disabled(controller.history.isEmpty)
            }
        }
    }
}

// MARK: - Asset state row

func assetStateView(_ state: ServerAssets.AssetState) -> some View {
    Group {
        switch state {
        case .missing:
            Text("Not installed").font(.caption).foregroundStyle(.secondary)
        case .downloading(let p):
            ProgressView(value: p).frame(width: 120)
        case .verifying:
            Text("Verifying…").font(.caption).foregroundStyle(.secondary)
        case .extracting:
            Text("Installing…").font(.caption).foregroundStyle(.secondary)
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .failed(let r):
            Text(r).font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var controller: DictationController
    @State private var recordingShortcut = false
    @State private var shortcutMonitor: Any?

    var micStatusText: String {
        switch controller.micPermission {
        case .granted: return "granted"
        case .denied: return "denied — grant access to record"
        case .unknown: return "not determined yet"
        }
    }

    func startShortcutCapture() {
        recordingShortcut = true
        // Local monitors dispatch on the main thread, so MainActor access is safe.
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in
            let code = e.keyCode
            MainActor.assumeIsolated {
                HotkeyManager.shared.setPushToTalk(keyCode: Int(code))
                self.stopShortcutCapture()
            }
            return e
        }
    }

    func stopShortcutCapture() {
        recordingShortcut = false
        if let m = shortcutMonitor { NSEvent.removeMonitor(m) }
        shortcutMonitor = nil
    }

    var body: some View {
        TabView {
            Form {
                Picker("Cleanup mode", selection: $controller.cleanupMode) {
                    Text("Clean (default)").tag(CleanupMode.clean)
                    Text("Verbatim").tag(CleanupMode.verbatim)
                }
                Picker("Transcription", selection: $controller.backendPreference) {
                    Text("Omil server (Whisper + Qwen, recommended)").tag(BackendChoice.omilServer)
                    Text("Automatic (on-device)").tag(BackendChoice.automatic)
                    Text("System speech").tag(BackendChoice.appleSpeech)
                    Text("Legacy on-device").tag(BackendChoice.legacySFSpeech)
                }
                Text("Backend: \(controller.backendDescription)")
                    .font(.caption)
                Text("Assets: \(controller.assetState)")
                    .font(.caption)
                HStack {
                    Button("Refresh model status") {
                        Task { await controller.refreshBackendStatus() }
                    }
                    Button("Download system assets") {
                        controller.downloadAssets()
                    }
                }
                Text("Changing transcription never changes cleanup behavior. The owned inference core lives under Models in the main window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Changing transcription never changes cleanup behavior.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .tabItem { Label("General", systemImage: "gear") }
            .padding()

            Form {
                Section("Microphone") {
                    Text("Status: \(micStatusText)")
                    HStack {
                        Button("Request microphone access") {
                            controller.requestMic()
                        }
                        .disabled(controller.micPermission == .granted)
                        Button("Open Microphone settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                        }
                    }
                    Text("Recording is visible in the menu bar and recorder window. Raw audio is never stored.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Direct insertion (Accessibility)") {
                    Text("Status: \(controller.axTrusted ? "granted — Omil can insert into the focused field" : "not granted — Omil will keep results for copy/paste")")
                    HStack {
                        Button("Ask for access…") {
                            controller.requestAXTrust()
                        }
                        .disabled(controller.axTrusted)
                        Button("Check again") {
                            controller.refreshMicPermission()
                        }
                        Button("Open Accessibility settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                    Text("Undo reverses only Omil's insertion, and refuses when you typed after it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Shortcuts") {
                    HStack {
                        Text("Push-to-talk: \(HotkeyManager.shared.pushToTalkName)")
                        Spacer()
                        if recordingShortcut {
                            Button("Cancel") { stopShortcutCapture() }
                        } else {
                            Button("Change…") { startShortcutCapture() }
                        }
                    }
                    if recordingShortcut {
                        Text("Press a modifier key (Option, Control, Command, Shift, or Fn)…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Toggle shortcut (Ctrl+Option+O)", isOn: Binding(
                        get: { HotkeyManager.shared.toggleEnabled },
                        set: { HotkeyManager.shared.toggleEnabled = $0 }
                    ))
                    Text("Background shortcuts need Input Monitoring permission. The Start/Stop buttons always work.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tabItem { Label("Permissions", systemImage: "mic.badge.plus") }
            .padding()
            .onAppear { controller.refreshMicPermission() }
        }
        .frame(minWidth: 480, minHeight: 420)
    }
}
