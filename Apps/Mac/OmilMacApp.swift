import SwiftUI
import OmilCore

// MARK: - Omil Mac app (menu bar agent, owns the inference server)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var controller: DictationController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("Omil launched")
        controller?.startup()
        if let c = controller { PillManager.shared.attach(c) }
        // Agent apps (LSUIElement) don't activate on their own — bring the
        // right window forward explicitly. Retry: scenes may not exist yet.
        NSApp.activate(ignoringOtherApps: true)
        attemptOrderFront(tries: 20)
    }

    private func attemptOrderFront(tries: Int) {
        if orderFront() { return }
        guard tries > 0 else {
            NSLog("Omil: startup window never appeared")
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self?.attemptOrderFront(tries: tries - 1)
        }
    }

    /// Onboarding first, main window after (both live in the "Omil" window).
    @discardableResult
    private func orderFront() -> Bool {
        orderWindowFront(title: "Omil")
    }

    /// openWindow is unreliable from MenuBarExtra content — order the
    /// SwiftUI Window scene's NSWindow forward directly.
    /// - Returns: whether a main window was found.
    @discardableResult
    func openMainWindow() -> Bool {
        NSLog("Omil: Open Omil pressed")
        return orderWindowFront(title: "Omil")
    }

    @discardableResult
    private func orderWindowFront(title: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.title == title && $0.canBecomeMain }) {
            w.makeKeyAndOrderFront(nil)
            NSLog("Omil: window '%@' front", title)
            return true
        } else if let w = NSApp.windows.first(where: { $0.title == title }) {
            w.orderFrontRegardless()
            NSLog("Omil: window '%@' front (regardless)", title)
            return true
        } else {
            NSLog("Omil: window '%@' not found among %d windows", title, NSApp.windows.count)
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
            Group {
                if controller.onboarded {
                    MainWindowView(controller: controller)
                        .frame(minWidth: 760, minHeight: 520)
                } else {
                    OnboardingView(controller: controller)
                }
            }
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

            Button("Open Omil") {
                (NSApp.delegate as? AppDelegate)?.openMainWindow()
            }

            Divider()

            if controller.phase == .recording {
                Button("Stop") { controller.stop() }
                    .keyboardShortcut(".", modifiers: [.command])
            } else {
                Button("Start dictation") { controller.toggle() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(controller.phase == .preparing || controller.phase == .processing)
            }

            Button("Paste last result") { controller.pasteLast() }
                .disabled(controller.lastCleaned.isEmpty)

            Divider()

            Button("Quit Omil") { NSApp.terminate(nil) }
        }
        .padding()
        .frame(width: 240)
    }

    var statusTitle: String {
        switch controller.phase {
        case .idle: return "Omil"
        case .preparing: return "Omil — preparing"
        case .recording: return "Omil — recording"
        case .processing: return "Omil — finalizing"
        case .ready: return "Omil"
        case .failed: return "Omil — attention needed"
        }
    }
}

// MARK: - History

struct HistoryView: View {
    @ObservedObject var controller: DictationController
    @State private var search = ""
    @State private var hovered: UUID?
    @State private var confirmDelete: DictationController.HistoryEntry?

    var filtered: [(day: Date, entries: [DictationController.HistoryEntry])] {
        let groups = controller.historyByDay
        guard !search.isEmpty else { return groups }
        let q = search.lowercased()
        return groups.compactMap { day, entries in
            let hit = entries.filter {
                $0.cleaned.lowercased().contains(q) || $0.raw.lowercased().contains(q)
            }
            return hit.isEmpty ? nil : (day, hit)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if controller.history.isEmpty {
                    ContentUnavailableView(
                        "No history",
                        systemImage: "mic.slash",
                        description: Text("Dictation results appear here when history is on. Raw audio is never stored.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filtered, id: \.day) { day, entries in
                            Section(controller.dayLabel(for: day)) {
                                ForEach(entries) { entry in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.cleaned)
                                            .font(.body)
                                            .textSelection(.enabled)
                                        Text("Raw: \(entry.raw)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                        HStack {
                                            Text("\(entry.date.formatted(date: .omitted, time: .shortened)) • \(entry.wordCount) words • \(entry.backend)")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                            Spacer()
                                            if hovered == entry.id {
                                                Button("Copy") {
                                                    NSPasteboard.general.declareTypes([.string], owner: nil)
                                                    NSPasteboard.general.setString(entry.cleaned, forType: .string)
                                                }
                                                .buttonStyle(.bordered)
                                                Button("Delete") { confirmDelete = entry }
                                                    .buttonStyle(.bordered)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    .onHover { hovering in
                                        hovered = hovering ? entry.id : nil
                                    }
                                }
                            }
                        }
                    }
                    .searchable(text: $search, prompt: "Search transcripts")
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
            .confirmationDialog(
                "Delete this transcript? This is permanent.",
                isPresented: Binding(
                    get: { confirmDelete != nil },
                    set: { if !$0 { confirmDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let entry = confirmDelete { controller.deleteHistoryEntry(entry) }
                    confirmDelete = nil
                }
                Button("Cancel", role: .cancel) { confirmDelete = nil }
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

            Form {
                Section("Startup") {
                    Toggle("Launch at login", isOn: Binding(
                        get: { controller.launchAtLogin },
                        set: { controller.launchAtLogin = $0 }
                    ))
                }
                Section("Dictation control") {
                    Toggle("Floating pill while recording", isOn: Binding(
                        get: { controller.pillEnabled },
                        set: { controller.setPillEnabled($0) }
                    ))
                    Text("The pill shows the live draft with Stop/Cancel where you work. The menu bar icon always shows recording state.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tabItem { Label("System", systemImage: "desktopcomputer") }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 420)
    }
}
