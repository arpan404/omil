import SwiftUI
import OmilCore

// MARK: - Omil Mac app (menu bar client)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Single shared controller — no init-time wiring to go stale.
    var controller: DictationController { AppContext.controller }
    private var mainWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
    static let localServer = LocalServerManager()
    static let controller = DictationController(localServer: localServer)
}

@main
@MainActor
struct OmilMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(controller: AppContext.controller)
        } label: {
            Label("Omil", systemImage: "mic")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(controller: AppContext.controller)
                .frame(minWidth: 700, minHeight: 520)
        }
    }
}

// MARK: - Menu bar

struct MenuBarView: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                OmilMark(size: 32, active: controller.phase == .recording)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Omil")
                        .font(OmilType.display(16))
                    Text(statusTitle)
                        .font(OmilType.utility(9, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
                Spacer()
                Button {
                    (NSApp.delegate as? AppDelegate)?.openMainWindow()
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(OmilTheme.muted)
                .help("Open Omil")
            }
            .padding(14)

            Group {
                if controller.phase == .recording {
                    SignalRail(levels: controller.audioLevels, active: true)
                } else if controller.phase == .processing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(OmilTheme.signal)
                } else {
                    Color.clear
                }
            }
            .frame(height: 42)
            .padding(.horizontal, 18)

            Button {
                controller.toggle()
            } label: {
                Label(controller.phase == .recording ? "Stop recording" : "Start dictation",
                      systemImage: controller.phase == .recording ? "stop.fill" : "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SignalButtonStyle())
            .disabled(
                controller.phase == .preparing
                    || controller.phase == .processing
                    || !controller.serverIsReady
            )
            .padding(14)

            if !controller.lastCleaned.isEmpty {
                Divider().overlay(OmilTheme.line)
                VStack(alignment: .leading, spacing: 8) {
                    Text("LAST RESULT")
                        .font(OmilType.utility(9, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(OmilTheme.faint)
                    Text(controller.lastCleaned)
                        .font(.system(size: 12))
                        .lineLimit(3)
                    HStack {
                        Button("Copy") { controller.copyLast() }
                        Button("Paste") { controller.pasteLast() }
                    }
                    .buttonStyle(QuietButtonStyle())
                }
                .padding(14)
            }

            Divider().overlay(OmilTheme.line)
            HStack {
                Button("Open Omil") { (NSApp.delegate as? AppDelegate)?.openMainWindow() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(OmilTheme.muted)
            .padding(14)
        }
        .frame(width: 290)
        .background(OmilTheme.panel)
        .preferredColorScheme(controller.appearance.colorScheme)
    }

    var statusTitle: String {
        switch controller.phase {
        case .idle: return controller.serverIsReady ? "READY" : "SETUP NEEDED"
        case .preparing: return "PREPARING"
        case .recording: return "RECORDING"
        case .processing: return "CLEANING UP"
        case .ready: return "RESULT READY"
        case .failed: return "CHECK SETUP"
        }
    }

    var statusColor: Color {
        switch controller.phase {
        case .recording: return OmilTheme.coral
        case .failed: return OmilTheme.warning
        case .preparing, .processing: return OmilTheme.signal
        case .idle: return controller.serverIsReady ? OmilTheme.mint : OmilTheme.warning
        case .ready: return OmilTheme.mint
        }
    }
}

// MARK: - Settings

private enum SettingsPane: String, CaseIterable {
    case general = "General"
    case permissions = "Permissions"
    case shortcuts = "Shortcuts"

    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .permissions: return "lock.shield"
        case .shortcuts: return "command"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var controller: DictationController
    @State private var pane: SettingsPane = .general
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
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    OmilMark(size: 32, active: false)
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
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                Spacer()
                Text("Audio stays on your Mac")
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
                    }
                }
                .padding(28)
            }
            .background(OmilTheme.canvas)
        }
        .frame(minWidth: 700, minHeight: 520)
        .preferredColorScheme(controller.appearance.colorScheme)
        .onAppear {
            controller.refreshMicPermission()
            controller.refreshAXTrust()
        }
        .onDisappear { stopShortcutCapture() }
    }

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsPageHeader(title: "General", detail: "How Omil records, cleans, and starts.")

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
                    Picker("", selection: $controller.cleanupMode) {
                        Text("Clean").tag(CleanupMode.clean)
                        Text("Verbatim").tag(CleanupMode.verbatim)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                }
                SettingsDivider()
                SettingsRow(title: "Floating pill", detail: "Keep recording and processing visible above other apps.") {
                    Toggle("", isOn: Binding(
                        get: { controller.pillEnabled },
                        set: { controller.setPillEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }

            SettingsGroup(title: "This Mac") {
                SettingsRow(title: "Launch at login", detail: "Start Omil after you sign in.") {
                    Toggle("", isOn: Binding(
                        get: { controller.launchAtLogin },
                        set: { controller.launchAtLogin = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow(
                    title: controller.usesCustomServer ? "Other server" : "Local engine",
                    detail: controller.serverHealth
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
        }
    }

    private var permissionsPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsPageHeader(title: "Permissions", detail: "Two permissions make dictation work anywhere.")

            SettingsGroup(title: "Microphone") {
                PermissionSettingsRow(
                    icon: "mic.fill",
                    title: controller.micPermission == .granted ? "Microphone allowed" : "Microphone access needed",
                    detail: controller.micPermission == .granted
                        ? "Omil can record. Raw audio is discarded after transcription."
                        : "Allow access before starting a recording.",
                    granted: controller.micPermission == .granted,
                    actionTitle: controller.micPermission == .denied ? "Open Settings" : "Allow"
                ) {
                    controller.requestMic()
                }
            }

            SettingsGroup(title: "Typing into apps") {
                PermissionSettingsRow(
                    icon: "cursorarrow.motionlines",
                    title: controller.axTrusted ? "Direct insertion allowed" : "Accessibility access needed",
                    detail: controller.axTrusted
                        ? "Omil can type the result into the field you started from."
                        : "Without it, Omil keeps the result ready to copy and paste.",
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
                    title: HotkeyManager.shared.pushToTalkName,
                    detail: recordingShortcut ? "Press one modifier key now." : "Hold to record. Release to transcribe."
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
                    Toggle("", isOn: Binding(
                        get: { HotkeyManager.shared.toggleEnabled },
                        set: { HotkeyManager.shared.toggleEnabled = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                SettingsDivider()
                HStack(spacing: 9) {
                    Image(systemName: "info.circle")
                    Text("Background shortcuts need Input Monitoring access. The recorder buttons always work.")
                }
                .font(.system(size: 10))
                .foregroundStyle(OmilTheme.faint)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
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
            Text(title.uppercased())
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
                    .lineLimit(2)
            }
            Spacer(minLength: 16)
            accessory()
        }
        .padding(.horizontal, 16)
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
                    .lineLimit(2)
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
