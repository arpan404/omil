import SwiftUI
import Combine
import OmilCore

// MARK: - Omil Mac app (menu bar client)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Single shared controller — no init-time wiring to go stale.
    var controller: DictationController { AppContext.controller }
    private var mainWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppContext.appDelegate = self
        NSLog("Omil launched")
        controller.startup()
        PillManager.shared.attach(controller)
        showMainWindow()
    }

    /// The main window is a plain AppKit window hosting SwiftUI content:
    /// deterministic, unlike the SwiftUI Window scene which never
    /// materialized in this app.
    func showMainWindow() {
        let c = controller
        if mainWindowController == nil {
            let launchScreen = preferredScreen()
            let visible = launchScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1120, height: 740)
            let contentSize = NSSize(
                width: min(1040, max(760, visible.width - 32)),
                height: min(680, max(540, visible.height - 32))
            )
            let hosting = NSHostingView(rootView: RootView(controller: c))
            hosting.frame = NSRect(origin: .zero, size: contentSize)
            hosting.autoresizingMask = [.width, .height]
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: contentSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "Omil"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.minSize = NSSize(
                width: min(760, visible.width - 16),
                height: min(540, visible.height - 16)
            )
            window.backgroundColor = .windowBackgroundColor
            window.contentView = hosting
            position(window, in: visible)
            window.isReleasedWhenClosed = false
            mainWindowController = NSWindowController(window: window)
        }
        if let window = mainWindowController?.window, !isVisibleOnAnyScreen(window) {
            let visible = preferredScreen()?.visibleFrame ?? NSScreen.screens.first?.visibleFrame
            if let visible { position(window, in: visible) }
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        NSLog("Omil: main window shown (visible=%d)",
              mainWindowController?.window?.isVisible == true ? 1 : 0)
    }

    private func preferredScreen() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) })
            ?? NSScreen.screens.first
    }

    private func position(_ window: NSWindow, in visible: NSRect) {
        window.setFrameOrigin(NSPoint(
            x: visible.midX - window.frame.width / 2,
            y: visible.midY - window.frame.height / 2
        ))
    }

    private func isVisibleOnAnyScreen(_ window: NSWindow) -> Bool {
        NSScreen.screens.contains { screen in
            let intersection = window.frame.intersection(screen.visibleFrame)
            return intersection.width >= 240 && intersection.height >= 160
        }
    }

    /// Kept for the menu action name.
    @discardableResult
    func openMainWindow() -> Bool {
        NSLog("Omil: Open Omil pressed")
        showMainWindow()
        return mainWindowController?.window?.isVisible == true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Dock icon click reopens the main window.
        if !flag { showMainWindow() }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller.refreshMicPermission()
        controller.refreshAXTrust()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppContext.localServer.stop()
        HotkeyManager.shared.stop()
    }
}
@MainActor
enum AppContext {
    static weak var appDelegate: AppDelegate?
    static let menuBarIcon: NSImage = {
        // A small vector mark for the menu bar, independent of the Dock artwork.
        let icon = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            for rect in [
                NSRect(x: 0, y: 7, width: 2, height: 4),
                NSRect(x: 3, y: 5, width: 2, height: 8),
                NSRect(x: 13, y: 5, width: 2, height: 8),
                NSRect(x: 16, y: 7, width: 2, height: 4)
            ] {
                NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
            }
            let center = NSBezierPath(roundedRect: NSRect(x: 6, y: 2, width: 6, height: 14), xRadius: 3, yRadius: 3)
            center.append(NSBezierPath(roundedRect: NSRect(x: 8, y: 4, width: 2, height: 10), xRadius: 1, yRadius: 1))
            center.windingRule = .evenOdd
            center.fill()
            return true
        }
        icon.isTemplate = true
        icon.accessibilityDescription = "Omil"
        return icon
    }()
    static let recordingMenuBarIcon: NSImage = {
        let icon = NSImage(
            systemSymbolName: "record.circle.fill",
            accessibilityDescription: "Omil, recording"
        ) ?? menuBarIcon
        icon.isTemplate = true
        return icon
    }()
    static let localServer = LocalServerManager()
    static let controller = DictationController(localServer: localServer)
    static let menuBarRecordingState = MenuBarRecordingState(controller: controller)
    static let updater = UpdateController()
}

@main
struct OmilMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(controller: AppContext.controller)
        } label: {
            RecordingMenuBarLabel(state: AppContext.menuBarRecordingState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(controller: AppContext.controller)
                .frame(minWidth: 700, minHeight: 520)
        }
    }
}

/// Keep the status item subscribed only to phase changes. Microphone level
/// updates should redraw the open menu, not recreate the status bar image.
@MainActor
final class MenuBarRecordingState: ObservableObject {
    @Published private(set) var isRecording = false
    private var cancellable: AnyCancellable?

    init(controller: DictationController) {
        cancellable = controller.$phase
            .map { $0 == .recording }
            .removeDuplicates()
            .sink { [weak self] in self?.isRecording = $0 }
    }
}

/// Template images follow macOS menu-bar contrast.
private struct RecordingMenuBarLabel: View {
    @ObservedObject var state: MenuBarRecordingState

    var body: some View {
        if state.isRecording {
            Image(nsImage: AppContext.recordingMenuBarIcon)
                .accessibilityLabel("Omil, recording")
                .help("Omil is recording")
        } else {
            Image(nsImage: AppContext.menuBarIcon)
                .accessibilityLabel("Omil")
        }
    }
}

// MARK: - Menu bar

struct MenuBarView: View {
    @ObservedObject var controller: DictationController
    @Environment(\.openSettings) private var openSettings

    private var recording: Bool { controller.phase == .recording }
    private var busy: Bool { controller.phase == .preparing || controller.phase == .processing }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                OmilMark(size: 34)
                Text("Omil")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(HoverButtonStyle(cornerRadius: 7))
                .help("Settings")
                .accessibilityLabel("Settings")
            }
            .padding(18)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(recording ? OmilTheme.coral : controller.serverIsReady ? OmilTheme.mint : OmilTheme.warning)
                        .frame(width: 6, height: 6)
                    Text(statusTitle)
                        .font(.system(size: 13, weight: .medium))
                }
                if recording {
                    SignalRail(levels: controller.audioLevels, active: true)
                        .frame(height: 28)
                } else if busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(controller.statusMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(OmilTheme.muted)
                    }
                } else if controller.phase == .failed {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(OmilTheme.warning)
                        Text(controller.statusMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(OmilTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(3)
                            .help(controller.statusMessage)
                    }
                } else {
                    Text("Hold \(HotkeyManager.shared.pushToTalkName) in any text field. Release when you're done speaking.")
                        .font(.system(size: 12))
                        .foregroundStyle(OmilTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    controller.toggle(source: .menuBar)
                } label: {
                    HStack {
                        Image(systemName: recording ? "stop.fill" : "mic.fill")
                        Text(recording ? "Stop and transcribe" : "Start dictation")
                        Spacer()
                        if !recording { Text("⌃⌥O").foregroundStyle(OmilTheme.signalInk.opacity(0.65)) }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(SignalButtonStyle())
                .disabled(busy || (!recording && !controller.serverIsReady))
                if recording || controller.phase == .preparing {
                    Button("Cancel recording") { controller.cancel() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(OmilTheme.muted)
                }
            }
            .padding(16)
            .background(OmilTheme.panelLifted.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            if !controller.lastCleaned.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Last transcript")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(OmilTheme.muted)
                        Spacer()
                        Button { controller.copyLast() } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.plain)
                            .help("Copy transcript")
                            .accessibilityLabel("Copy transcript")
                    }
                    Text(controller.lastCleaned)
                        .font(.system(size: 12))
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }

            Divider()
            VStack(spacing: 2) {
                menuRow("Open Omil", icon: "macwindow", shortcut: "") {
                    AppContext.appDelegate?.showMainWindow()
                }
                menuRow("Show floating pill", icon: controller.pillEnabled ? "checkmark.circle.fill" : "circle", shortcut: "") {
                    controller.setPillEnabled(!controller.pillEnabled)
                }
                menuRow("Check for updates", icon: "arrow.down.circle", shortcut: "") {
                    AppContext.updater.checkForUpdates()
                }
                .disabled(!AppContext.updater.canCheckForUpdates)
                menuRow("Quit Omil", icon: "power", shortcut: "⌘Q") { NSApp.terminate(nil) }
            }
            .padding(8)
        }
        .frame(width: 320)
        .background(OmilTheme.panel)
        .foregroundStyle(OmilTheme.ink)
        .omilAppearance()
    }

    private func menuRow(_ title: String, icon: String, shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18)
                Text(title)
                Spacer()
                Text(shortcut).foregroundStyle(OmilTheme.muted)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
    }

    private var statusTitle: String {
        switch controller.phase {
        case .idle: return controller.serverIsReady ? "Ready to transcribe" : "Finish speech setup in Omil"
        case .preparing: return "Getting ready"
        case .recording: return "Listening"
        case .processing: return controller.processingStage.title
        case .ready: return controller.lastCleaned.isEmpty ? "No speech detected" : "Transcript ready"
        case .failed: return "Couldn't finish. Open Omil for details."
        }
    }
}

// MARK: - Settings

private enum SettingsPane: String, CaseIterable {
    case general = "General"
    case permissions = "Permissions"
    case shortcuts = "Shortcuts"
    case advanced = "Advanced"

    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .permissions: return "lock.shield"
        case .shortcuts: return "command"
        case .advanced: return "gearshape.2"
        }
    }
}

private enum SettingsPillMode: String, CaseIterable {
    case off = "Off"
    case duringDictation = "While dictating"
    case always = "Always"
}

struct SettingsView: View {
    @ObservedObject var controller: DictationController
    @State private var pane: SettingsPane = .general
    @ObservedObject private var hotkeys = HotkeyManager.shared
    @State private var pendingModifier: Int?
    @State private var shortcutError = ""
    @State private var recordingShortcut = false
    @State private var shortcutMonitor: Any?

    var micStatusText: String {
        switch controller.micPermission {
        case .granted: return "granted"
        case .denied: return "denied. Grant access to record"
        case .unknown: return "not determined yet"
        }
    }

    func startShortcutCapture() {
        stopShortcutCapture()
        recordingShortcut = true
        shortcutError = ""
        hotkeys.capturingShortcut = true
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            let consumed = MainActor.assumeIsolated {
                if event.type == .keyDown {
                    if event.keyCode == 53 {
                        self.stopShortcutCapture()
                    } else if self.hotkeys.setPushToTalk(
                        keyCode: Int(event.keyCode),
                        modifiers: event.modifierFlags,
                        character: event.charactersIgnoringModifiers ?? ""
                    ) {
                        self.stopShortcutCapture()
                    } else {
                        self.pendingModifier = nil
                        self.shortcutError = "Choose a modifier or a different key combination."
                    }
                    return true
                }
                let code = Int(event.keyCode)
                if let flag = HotkeyManager.modifierFlag(for: code) {
                    if event.modifierFlags.contains(flag) {
                        self.pendingModifier = code
                    } else if self.pendingModifier == code {
                        self.hotkeys.setPushToTalk(keyCode: code)
                        self.stopShortcutCapture()
                    }
                }
                return false
            }
            return consumed ? nil : event
        }
    }

    func stopShortcutCapture() {
        recordingShortcut = false
        pendingModifier = nil
        hotkeys.capturingShortcut = false
        if let monitor = shortcutMonitor { NSEvent.removeMonitor(monitor) }
        shortcutMonitor = nil
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    OmilMark(size: 32)
                    Text("Settings")
                        .font(OmilType.display(17))
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 22)

                VStack(spacing: 4) {
                    ForEach(SettingsPane.allCases, id: \.self) { item in
                        Button {
                            pane = item
                        } label: {
                            Label(item.rawValue, systemImage: item.icon)
                                .font(.system(size: 12, weight: pane == item ? .semibold : .medium))
                                .foregroundStyle(pane == item ? OmilTheme.ink : OmilTheme.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .frame(height: 36)
                                .background(
                                    pane == item ? OmilTheme.panelLifted : .clear,
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                        }
                        .buttonStyle(HoverButtonStyle())
                        .accessibilityAddTraits(pane == item ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 10)
                Spacer()
                Text(controller.usesCustomServer ? "Using your transcription server" : "Speech processing on this Mac")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(OmilTheme.faint)
                    .padding(16)
            }
            .frame(width: 168)
            .background(OmilTheme.sidebar)

            Divider().overlay(OmilTheme.line)

            ScrollView {
                Group {
                    switch pane {
                    case .general: generalPane
                    case .permissions: permissionsPane
                    case .shortcuts: shortcutsPane
                    case .advanced: advancedPane
                    }
                }
                .padding(28)
            }
            .id(pane)
            .background(OmilTheme.canvas)
        }
        .frame(minWidth: 700, minHeight: 520)
        .omilAppearance()
        .onAppear {
            controller.refreshMicPermission()
            controller.refreshAXTrust()
        }
        .onDisappear { stopShortcutCapture() }
        .onChange(of: pane) { _, _ in stopShortcutCapture() }
    }

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsPageHeader(title: "General", detail: "Choose how Omil looks and handles your dictation.")

            SettingsGroup(title: "Appearance") {
                SettingsRow(title: "Theme", detail: "Follow this Mac or keep Omil light or dark.") {
                    Picker("Theme", selection: $controller.appearance) {
                        ForEach(AppearancePreference.allCases) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)
                }
            }

            SettingsGroup(title: "Dictation") {
                SettingsRow(title: "Cleanup", detail: "Clean removes fillers. Verbatim keeps every spoken word.") {
                    Picker("Cleanup", selection: $controller.cleanupMode) {
                        Text("Clean").tag(CleanupMode.clean)
                        Text("Verbatim").tag(CleanupMode.verbatim)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                }
                SettingsDivider()
                SettingsRow(title: "Speech sensitivity", detail: controller.speechSensitivity.detail) {
                    Picker("Speech sensitivity", selection: $controller.speechSensitivity) {
                        ForEach(SpeechSensitivity.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                SettingsDivider()
                SettingsRow(title: "Automatically copy transcripts", detail: "Copy each finished transcript to the clipboard.") {
                    Toggle("Automatically copy transcripts", isOn: $controller.automaticallyCopyTranscripts)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow(title: "Floating pill", detail: "Always keeps a Start control on your desktop. Drag the handle to move it.") {
                    Picker("Floating pill", selection: Binding(
                        get: {
                            if !controller.pillEnabled { return SettingsPillMode.off }
                            return controller.pillAlwaysVisible ? .always : .duringDictation
                        },
                        set: { mode in
                            switch mode {
                            case .off: controller.setPillEnabled(false)
                            case .duringDictation:
                                controller.setPillAlwaysVisible(false)
                                controller.setPillEnabled(true)
                            case .always: controller.setPillAlwaysVisible(true)
                            }
                        }
                    )) {
                        ForEach(SettingsPillMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                SettingsDivider()
                SettingsRow(
                    title: "Saved recordings",
                    detail: controller.audioRetentionDays == 0
                        ? "Off. Existing saved recordings are removed."
                        : "Keep recordings on this Mac to listen back or transcribe again."
                ) {
                    Picker("Retention", selection: Binding(
                        get: { controller.audioRetentionDays },
                        set: { controller.setAudioRetentionDays($0) }
                    )) {
                        Text("Off").tag(0)
                        Text("1 day").tag(1)
                        Text("3 days").tag(3)
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
            }

            SettingsGroup(title: "This Mac") {
                SettingsRow(title: "Launch at login", detail: "Start Omil after you sign in.") {
                    Toggle("Launch at login", isOn: Binding(
                        get: { controller.launchAtLogin },
                        set: { controller.launchAtLogin = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow(
                    title: controller.usesCustomServer ? "Other server" : "Local engine",
                    detail: controller.speechSetupSummary
                ) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(controller.serverIsReady ? OmilTheme.mint : OmilTheme.warning)
                            .frame(width: 7, height: 7)
                        Button("Check") { Task { await controller.refreshBackendStatus() } }
                            .buttonStyle(QuietButtonStyle())
                    }
                }
            }

            SettingsGroup(title: "Getting started") {
                SettingsRow(title: "Review setup", detail: "Check permissions and try your first dictation again.") {
                    Button("Show setup") {
                        controller.onboarded = false
                        AppContext.appDelegate?.showMainWindow()
                    }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(controller.phase == .recording || controller.phase == .preparing || controller.phase == .processing)
                }
            }

            SettingsGroup(title: "Updates") {
                SettingsRow(title: AppVersion.display, detail: "Updates are delivered from GitHub Releases.") {
                    Button("Check now") { AppContext.updater.checkForUpdates() }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(!AppContext.updater.canCheckForUpdates)
                }
            }
        }
    }

    private var permissionsPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsPageHeader(title: "Permissions", detail: "Manage microphone access and writing in other apps.")

            SettingsGroup(title: "Microphone") {
                PermissionSettingsRow(
                    icon: "mic.fill",
                    title: controller.micPermission == .granted ? "Microphone allowed" : "Microphone access needed",
                    detail: controller.micPermission == .granted
                        ? "Omil can hear you during dictation. Manage saved recordings in General."
                        : "Allow access before starting a recording.",
                    granted: controller.micPermission == .granted,
                    actionTitle: controller.micPermission == .granted ? "Check again" : controller.micPermission == .denied ? "Open Settings" : "Allow"
                ) {
                    controller.micPermission == .granted ? controller.refreshMicPermission() : controller.requestMic()
                }
            }

            SettingsGroup(title: "Writing in other apps") {
                PermissionSettingsRow(
                    icon: "cursorarrow.motionlines",
                    title: controller.axTrusted ? "Accessibility allowed" : "Accessibility access needed",
                    detail: controller.axTrusted
                        ? "Your transcript appears where you started dictating."
                        : "Allow access to put your transcript directly in other apps.",
                    granted: controller.axTrusted,
                    actionTitle: controller.axTrusted ? "Check again" : "Allow"
                ) {
                    controller.axTrusted ? controller.refreshAXTrust() : controller.requestAXTrust()
                }
                SettingsDivider()
                SettingsRow(title: "System Settings", detail: "Review or remove Accessibility access.") {
                    Button("Open") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .buttonStyle(QuietButtonStyle())
                }
            }
        }
    }

    private var shortcutsPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsPageHeader(title: "Shortcuts", detail: "Start dictation without leaving the app you are using.")

            SettingsGroup(title: "Push to talk") {
                SettingsRow(
                    title: recordingShortcut ? "Press a shortcut" : hotkeys.pushToTalkName,
                    detail: recordingShortcut ? (shortcutError.isEmpty ? "A modifier key or a key combination." : shortcutError) : "Hold to speak. Release to transcribe."
                ) {
                    if recordingShortcut {
                        Button("Cancel") { stopShortcutCapture() }
                            .buttonStyle(QuietButtonStyle())
                    } else {
                        Button("Change") { startShortcutCapture() }
                            .buttonStyle(SignalButtonStyle())
                    }
                }
            }

            SettingsGroup(title: "Hands-free") {
                SettingsRow(title: "Control + Option + O", detail: "Press once to start and once to stop.") {
                    Toggle("Hands-free shortcut", isOn: Binding(
                        get: { HotkeyManager.shared.toggleEnabled },
                        set: { HotkeyManager.shared.toggleEnabled = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }

            }
        }
    }

    private var advancedPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsPageHeader(title: "Advanced", detail: "Control how the server cleans your transcripts.")
            SettingsGroup(title: "Cleanup system prompt") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Sent with each cleanup request from this Mac. Leave the override off to use the server's current prompt.")
                        .font(.system(size: 11))
                        .foregroundStyle(OmilTheme.muted)
                    TextEditor(text: $controller.promptText)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 220)
                        .padding(10)
                        .background(OmilTheme.canvas, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(OmilTheme.lineStrong))
                        .accessibilityLabel("Cleanup system prompt")
                    HStack {
                        Text(controller.promptCustom ? "Using your prompt" : "Using server prompt")
                            .font(OmilType.utility(10))
                            .foregroundStyle(OmilTheme.muted)
                        Spacer()
                        Button("Use server prompt") { controller.resetPrompt() }
                            .disabled(!controller.promptCustom)
                        Button("Save prompt") { controller.savePrompt() }
                            .disabled(controller.promptText.trimmingCharacters(in: .whitespacesAndNewlines).count < 50 || controller.promptText.count > 50_000)
                            .buttonStyle(SignalButtonStyle())
                    }
                    if !controller.serverOpNote.isEmpty {
                        Text(controller.serverOpNote)
                            .font(.system(size: 10))
                            .foregroundStyle(OmilTheme.muted)
                    }
                }
                .padding(16)
            }
        }
        .onAppear { controller.loadPrompt() }
    }
}

private struct SettingsPageHeader: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(OmilType.display(25))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(OmilTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(OmilType.utility(9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(OmilTheme.faint)
                .padding(.leading, 3)
            VStack(spacing: 0) { content() }
                .background(OmilTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(OmilTheme.line))
        }
    }
}

private struct SettingsRow<Accessory: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OmilTheme.ink)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(OmilTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            accessory()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 64)
    }
}

private struct PermissionSettingsRow: View {
    let icon: String
    let title: String
    let detail: String
    let granted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: granted ? "checkmark" : icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(granted ? OmilTheme.mint : OmilTheme.signal)
                .frame(width: 34, height: 34)
                .background(
                    (granted ? OmilTheme.mint : OmilTheme.signal).opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 9)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(OmilTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 14)
            if granted {
                Button(actionTitle, action: action)
                    .buttonStyle(QuietButtonStyle())
            } else {
                Button(actionTitle, action: action)
                    .buttonStyle(SignalButtonStyle())
            }
        }
        .padding(16)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .overlay(OmilTheme.line)
            .padding(.leading, 16)
    }
}
