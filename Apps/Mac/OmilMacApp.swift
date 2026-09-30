import SwiftUI
import OmilDesign
import Combine
import OmilCore

// MARK: - Omil Mac app (menu bar client)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: DictationController { AppContext.controller }
    private var mainWindowController: NSWindowController?
    private var settingsWindowController: NSWindowController?
    private var installationPending = InstallationFlow.requiresInstallation()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if installationPending {
            _ = InstallationFlow.handleLaunch()
            return
        }
        AppContext.appDelegate = self
        controller.startup()
        PillManager.shared.attach(controller)
        showMainWindow()
    }

    /// The main window is an AppKit window hosting SwiftUI, so it can be shown
    /// from the menu bar, intents, and Dock clicks without a Window scene.
    func showMainWindow(section: MainSection) {
        AppNavigation.shared.section = section
        showMainWindow()
    }

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
            window.toolbarStyle = .unified
            window.minSize = NSSize(
                width: min(760, visible.width - 16),
                height: min(540, visible.height - 16)
            )
            window.isOpaque = false
            window.backgroundColor = .clear
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
    }

    /// Settings get their own window, like other Mac apps, instead of a sheet
    /// that blocks the main window.
    func showSettings() {
        if settingsWindowController == nil {
            let size = NSSize(width: 820, height: 600)
            let hosting = NSHostingView(rootView: SettingsView(controller: controller))
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.autoresizingMask = [.width, .height]
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "Settings"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.minSize = NSSize(width: 720, height: 520)
            window.collectionBehavior = [.fullScreenNone]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = hosting
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("OmilSettings")
            settingsWindowController = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !installationPending else { return false }
        // Dock icon click reopens the main window.
        if !flag { showMainWindow() }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !installationPending else { return }
        controller.refreshMicPermission()
        controller.refreshAXTrust()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !installationPending else { return }
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
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    AppContext.appDelegate?.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
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
    @ObservedObject private var hotkeys = HotkeyManager.shared
    @State private var copied = false

    private var recording: Bool { controller.phase == .recording }
    private var busy: Bool { controller.phase == .preparing || controller.phase == .processing }

    var body: some View {
        VStack(spacing: 10) {
            header
            dictationModule
            if !controller.lastCleaned.isEmpty {
                lastTranscriptModule
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            menuModule
        }
        .padding(10)
        .frame(width: 320)
        .foregroundStyle(OmilTheme.ink)
        .animation(OmilMotion.standard, value: controller.phase)
        .animation(OmilMotion.standard, value: controller.lastCleaned.isEmpty)
        .omilAppearance()
    }

    private var header: some View {
        HStack(spacing: 10) {
            OmilMark(size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Omil")
                    .font(.system(size: 14, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(statusTitle)
                        .contentTransition(.opacity)
                }
                .font(OmilFont.caption)
                .foregroundStyle(OmilTheme.muted)
            }
            Spacer()
            Button {
                AppContext.appDelegate?.showSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(IconButtonStyle())
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    private var dictationModule: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                if recording {
                    LiveSignalRail(meter: controller.audioMeter)
                        .frame(height: 30)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                } else if busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(controller.phase == .processing ? controller.processingStage.title : "Getting ready…")
                            .font(OmilFont.callout)
                            .foregroundStyle(OmilTheme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
                } else if controller.phase == .failed {
                    Label(controller.statusMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(OmilFont.callout)
                        .foregroundStyle(OmilTheme.muted)
                        .symbolRenderingMode(.hierarchical)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                } else {
                    Text("Hold \(hotkeys.pushToTalkName) in any text field, or start here.")
                        .font(OmilFont.callout)
                        .foregroundStyle(OmilTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }
            }
            .frame(minHeight: 30)

            HStack(spacing: 8) {
                Button {
                    controller.toggle(source: .menuBar)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: recording ? "stop.fill" : "mic.fill")
                            .contentTransition(.symbolEffect(.replace))
                        Text(recording ? "Stop and Transcribe" : "Start Dictation")
                        Spacer()
                        if !recording && hotkeys.toggleEnabled {
                            Text(HotkeyManager.toggleShortcutSymbol)
                                .opacity(0.6)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .omilButton(prominent: true, tint: recording ? OmilTheme.coral : nil)
                .controlSize(.large)
                .disabled(busy || (!recording && !controller.serverIsReady))

                if recording || controller.phase == .preparing {
                    Button {
                        controller.cancel()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(IconButtonStyle(destructive: true))
                    .help("Cancel Recording")
                    .accessibilityLabel("Cancel Recording")
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .padding(12)
        .background(OmilTheme.groupFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var lastTranscriptModule: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Last Transcript")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OmilTheme.muted)
                Spacer()
                Button {
                    controller.copyLast()
                    withAnimation(OmilMotion.quick) { copied = true }
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.4))
                        withAnimation(OmilMotion.quick) { copied = false }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(IconButtonStyle())
                .help(copied ? "Copied" : "Copy Transcript")
                .accessibilityLabel(copied ? "Copied" : "Copy transcript")
            }
            Text(controller.lastCleaned)
                .font(OmilFont.body)
                .lineLimit(3)
                .textSelection(.enabled)
                .contentTransition(.opacity)
        }
        .padding(12)
        .background(OmilTheme.groupFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var menuModule: some View {
        VStack(spacing: 0) {
            menuRow("Open Omil", icon: "macwindow") {
                AppContext.appDelegate?.showMainWindow()
            }
            menuToggleRow("Floating Pill", icon: "capsule", isOn: Binding(
                get: { controller.pillEnabled },
                set: { controller.setPillEnabled($0) }
            ))
            menuRow("Check for Updates…", icon: "arrow.down.circle") {
                AppContext.updater.checkForUpdates()
            }
            .disabled(!AppContext.updater.canCheckForUpdates)
            Divider().padding(.vertical, 4).padding(.horizontal, 8)
            menuRow("Quit Omil", icon: "power", shortcut: "⌘Q") { NSApp.terminate(nil) }
        }
        .padding(4)
        .background(OmilTheme.groupFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func menuRow(_ title: String, icon: String, shortcut: String = "", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(OmilTheme.muted)
                    .frame(width: 18)
                Text(title)
                Spacer()
                Text(shortcut).foregroundStyle(OmilTheme.muted)
            }
            .font(OmilFont.body)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
    }

    private func menuToggleRow(_ title: String, icon: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(OmilTheme.muted)
                .frame(width: 18)
            Text(title)
            Spacer()
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .font(OmilFont.body)
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    private var statusColor: Color {
        switch controller.phase {
        case .recording: return OmilTheme.coral
        case .failed: return OmilTheme.warning
        case .preparing, .processing: return OmilTheme.signal
        default: return controller.serverIsReady ? OmilTheme.mint : OmilTheme.warning
        }
    }

    private var statusTitle: String {
        switch controller.phase {
        case .idle: return controller.serverIsReady ? "Ready" : "Engine not ready"
        case .preparing: return "Getting ready"
        case .recording: return "Listening"
        case .processing: return controller.processingStage.title
        case .ready: return controller.lastCleaned.isEmpty ? "No speech detected" : "Transcript ready"
        case .failed: return "Couldn't finish"
        }
    }
}

// MARK: - Settings

private enum SettingsPane: String, CaseIterable {
    case general = "General"
    case appearance = "Appearance"
    case permissions = "Permissions"
    case shortcuts = "Shortcuts"
    case advanced = "Advanced"

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .appearance: return "paintbrush.pointed.fill"
        case .permissions: return "hand.raised.fill"
        case .shortcuts: return "command"
        case .advanced: return "wrench.and.screwdriver.fill"
        }
    }

    /// System Settings–style tile colors.
    var tint: Color {
        switch self {
        case .general: return Color(hex: 0x8E8E93)
        case .appearance: return Color(hex: 0x5E5CE6)
        case .permissions: return Color(hex: 0x0A84FF)
        case .shortcuts: return Color(hex: 0x636366)
        case .advanced: return Color(hex: 0x48484A)
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
    @ObservedObject private var appearance = AppAppearance.shared
    @AppStorage("omil.settingsPane") private var pane: SettingsPane = .general
    @Namespace private var paneSelection
    @ObservedObject private var hotkeys = HotkeyManager.shared
    @State private var pendingModifier: Int?
    @State private var shortcutError = ""
    @State private var recordingShortcut = false
    @State private var shortcutMonitor: Any?

    private var pillMode: SettingsPillMode {
        if !controller.pillEnabled { return .off }
        return controller.pillAlwaysVisible ? .always : .duringDictation
    }

    private func retentionTitle(_ days: Int) -> String {
        if days == 0 { return "Off" }
        return days == 1 ? "1 day" : "\(days) days"
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
        NavigationSplitView {
            List {
                ForEach(SettingsPane.allCases, id: \.self) { item in
                    ThemedSidebarRow(title: item.rawValue, selected: pane == item, namespace: paneSelection) {
                        SettingsIconTile(symbol: item.icon, tint: item.tint)
                    } action: {
                        withAnimation(OmilMotion.standard) { pane = item }
                    }
                    .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Text(AppVersion.display)
                    .font(OmilFont.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
            }
        } detail: {
            ZStack {
                Group {
                    switch pane {
                    case .general: generalPane
                case .appearance: appearancePane
                case .permissions: permissionsPane
                case .shortcuts: shortcutsPane
                    case .advanced: advancedPane
                    }
                }
                .id(pane)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .navigationTitle(pane.rawValue)
            .toastHost()
        }
        .frame(minWidth: 720, minHeight: 520)
        .id("\(appearance.themePreset.id)-\(appearance.colorScheme)")
        .omilAppearance(fullSizeTitlebar: true)
        .onAppear {
            controller.refreshMicPermission()
            controller.refreshAXTrust()
        }
        .onDisappear { stopShortcutCapture() }
        .onChange(of: pane) { _, _ in stopShortcutCapture() }
    }

    private var generalPane: some View {
        Form {

            Section("Dictation") {
                SettingsRow(title: "Cleanup", detail: "Clean removes fillers. Verbatim keeps every spoken word.") {
                    Picker("Cleanup", selection: $controller.cleanupMode) {
                        Text("Clean").tag(CleanupMode.clean)
                        Text("Verbatim").tag(CleanupMode.verbatim)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow(title: "Speech sensitivity", detail: controller.speechSensitivity.detail) {
                    OmilPickerField(
                        title: "Speech sensitivity",
                        selection: $controller.speechSensitivity,
                        options: SpeechSensitivity.allCases,
                        label: { $0.title }
                    )
                    .frame(width: 180)
                }
                SettingsRow(title: "Automatically copy transcripts", detail: "Copy each finished transcript to the clipboard.") {
                    Toggle("Automatically copy transcripts", isOn: $controller.automaticallyCopyTranscripts)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SettingsRow(title: "Floating pill", detail: "Always keeps a Start control on your desktop. Drag the pill background to move it.") {
                    OmilPickerField(
                        title: "Floating pill",
                        selection: Binding(
                            get: { pillMode },
                            set: { mode in
                                switch mode {
                                case .off: controller.setPillEnabled(false)
                                case .duringDictation:
                                    controller.setPillAlwaysVisible(false)
                                    controller.setPillEnabled(true)
                                case .always: controller.setPillAlwaysVisible(true)
                                }
                            }
                        ),
                        options: SettingsPillMode.allCases,
                        label: { $0.rawValue }
                    )
                    .frame(width: 150)
                }
                SettingsRow(
                    title: "Saved recordings",
                    detail: controller.audioRetentionDays == 0
                        ? "Off. Existing saved recordings are removed."
                        : "Keep recordings on this Mac to listen back or transcribe again."
                ) {
                    OmilPickerField(
                        title: "Retention",
                        selection: Binding(
                            get: { controller.audioRetentionDays },
                            set: { controller.setAudioRetentionDays($0) }
                        ),
                        options: [0, 1, 3, 7, 14, 30],
                        label: { retentionTitle($0) }
                    )
                    .frame(width: 120)
                }
            }

            Section("This Mac") {
                SettingsRow(title: "Launch at login", detail: "Start Omil after you sign in.") {
                    Toggle("Launch at login", isOn: Binding(
                        get: { controller.launchAtLogin },
                        set: { controller.launchAtLogin = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                SettingsRow(
                    title: controller.usesCustomServer ? "Other server" : "Local engine",
                    detail: controller.speechSetupSummary
                ) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(controller.serverIsReady ? OmilTheme.mint : OmilTheme.warning)
                            .frame(width: 7, height: 7)
                        Button("Check") {
                            Task { @MainActor in
                                await controller.refreshBackendStatus()
                                ToastCenter.shared.show(
                                    controller.serverIsReady ? "Engine Is Ready" : "Engine Needs Attention",
                                    symbol: controller.serverIsReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                                )
                            }
                        }
                            .omilButton()
                    }
                }
            }

            Section("Getting started") {
                SettingsRow(title: "Review setup", detail: "Check permissions and try your first dictation again.") {
                    Button("Show setup") {
                        controller.onboarded = false
                        AppContext.appDelegate?.showMainWindow()
                    }
                    .omilButton()
                    .disabled(controller.phase == .recording || controller.phase == .preparing || controller.phase == .processing)
                }
            }

            Section("Updates") {
                SettingsRow(title: AppVersion.display, detail: "Updates are delivered from GitHub Releases.") {
                    Button("Check now") { AppContext.updater.checkForUpdates() }
                        .omilButton()
                        .disabled(!AppContext.updater.canCheckForUpdates)
                }
            }
        }
    }

    private var appearancePane: some View {
        Form {
            Section("Appearance") {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(AppearancePreference.allCases) { scheme in
                        AppearanceChoice(title: scheme.title, selected: controller.appearance == scheme) {
                            switch scheme {
                            case .system:
                                PaletteThumbnail(light: controller.themePreset.palette(for: .light),
                                                 dark: controller.themePreset.palette(for: .dark))
                            case .light:
                                PaletteThumbnail(light: controller.themePreset.palette(for: .light))
                            case .dark:
                                PaletteThumbnail(light: controller.themePreset.palette(for: .dark))
                            }
                        } action: {
                            controller.appearance = scheme
                        }
                    }
                }
                .padding(.vertical, 10)
            }
            WindowTransparencySection()
            Section {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(ThemePreset.allCases) { preset in
                        AppearanceChoice(title: preset.title, subtitle: preset.detail,
                                         selected: controller.themePreset == preset) {
                            PaletteThumbnail(light: preset.palette(for: AppAppearance.shared.colorScheme))
                        } action: {
                            controller.themePreset = preset
                        }
                    }
                }
                .padding(.vertical, 10)
            } header: {
                Text("Theme")
            } footer: {
                Text("Themes change Omil's colors only. Your Mac's accent color is unaffected.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var permissionsPane: some View {
        Form {

            Section("Microphone") {
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

            Section("Writing in other apps") {
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
                SettingsRow(title: "System Settings", detail: "Review or remove Accessibility access.") {
                    Button("Open") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .omilButton()
                }
            }
        }
    }

    private var shortcutsPane: some View {
        Form {

            Section("Push to talk") {
                SettingsRow(
                    title: recordingShortcut ? "Press a shortcut" : hotkeys.pushToTalkName,
                    detail: recordingShortcut ? (shortcutError.isEmpty ? "A modifier key or a key combination." : shortcutError) : "Hold to speak. Release to transcribe."
                ) {
                    if recordingShortcut {
                        Button("Cancel") { stopShortcutCapture() }
                            .omilButton()
                    } else {
                        Button("Change") { startShortcutCapture() }
                            .omilButton(prominent: true)
                    }
                }
                if hotkeys.pushToTalkKeyCode == 63 && hotkeys.pushToTalkModifiers.isEmpty {
                    Text("If Fn also opens Emoji & Symbols, set “Press Fn key to” to “Do Nothing” in macOS Keyboard settings.")
                        .font(OmilFont.ui(11))
                        .foregroundStyle(OmilTheme.muted)
                }
            }

            Section("Hands-free") {
                SettingsRow(title: HotkeyManager.toggleShortcutName, detail: "Press once to start and once to stop.") {
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
        Form {
            CleanupPromptSection(controller: controller)
        }
    }
}

/// Edits a local draft so typing doesn't publish through the controller to
/// every observing view; the draft is written back on Save.
private struct CleanupPromptSection: View {
    @ObservedObject var controller: DictationController
    @State private var draft = ""

    private var draftIsValid: Bool {
        draft.count <= 50_000 && draft.trimmingCharacters(in: .whitespacesAndNewlines).count >= 50
    }

    var body: some View {
        Section("Cleanup prompt") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Guides full-text cleanup of grammar, spelling, and spoken corrections. Protected values and word-diff checks still apply.")
                    .font(OmilFont.caption)
                    .foregroundStyle(OmilTheme.muted)
                TextEditor(text: $draft)
                    .font(OmilFont.mono)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 220)
                    .background(OmilTheme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(OmilTheme.ink.opacity(0.08), lineWidth: 0.5))
                    .accessibilityLabel("Cleanup prompt")
                HStack {
                    Text(controller.promptCustom ? "Using your prompt" : "Using server prompt")
                        .font(OmilFont.caption)
                        .foregroundStyle(OmilTheme.muted)
                    Spacer()
                    Button("Use Server Prompt") {
                        controller.resetPrompt()
                        ToastCenter.shared.show("Using Server Prompt", symbol: "arrow.uturn.backward.circle.fill")
                    }
                    .omilButton()
                    .disabled(!controller.promptCustom)
                    Button("Save Prompt") {
                        controller.promptText = draft
                        controller.savePrompt()
                        ToastCenter.shared.show("Prompt Saved")
                    }
                    .omilButton(prominent: true)
                    .disabled(!draftIsValid || draft == controller.promptText && controller.promptCustom)
                }
                if !controller.serverOpNote.isEmpty {
                    Text(controller.serverOpNote)
                        .font(OmilFont.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        .onAppear {
            draft = controller.promptText
            controller.loadPrompt()
        }
        .onChange(of: controller.promptText) { _, text in draft = text }
    }
}

private struct SettingsIconTile: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.gradient)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            }
            .accessibilityHidden(true)
    }
}

/// Lets people choose how much of the desktop shows through Omil's windows.
private struct WindowTransparencySection: View {
    @ObservedObject private var appearance = AppAppearance.shared

    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: 10) {
                    Image(systemName: "square.fill")
                        .foregroundStyle(.secondary)
                        .help("Opaque")
                    Slider(value: $appearance.windowTransparency, in: 0...1)
                        .frame(width: 200)
                        .accessibilityLabel("Window transparency")
                        .accessibilityValue("\(Int(appearance.windowTransparency * 100)) percent")
                    Image(systemName: "square.dashed")
                        .foregroundStyle(.secondary)
                        .help("Clear")
                    Text("\(Int((appearance.windowTransparency * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
            } label: {
                Text("Window Transparency")
                Text(description)
            }
        } header: {
            HStack {
                Text("Window")
                Spacer()
                if abs(appearance.windowTransparency - AppAppearance.defaultTransparency) > 0.001 {
                    Button("Reset") {
                        withAnimation(OmilMotion.standard) {
                            appearance.windowTransparency = AppAppearance.defaultTransparency
                        }
                    }
                    .buttonStyle(.link)
                    .font(OmilFont.caption)
                }
            }
        }
    }

    private var description: String {
        switch appearance.windowTransparency {
        case ..<0.05: return "Solid background."
        case ..<0.86: return "Frosted glass shows your desktop softly."
        default: return "Clear glass. Text may be harder to read."
        }
    }
}

/// A window thumbnail drawn in a palette, like System Settings' appearance choices.
private struct MiniWindow: View {
    let colors: ThemePalette

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 2.5) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(Color(hex: colors.lineStrong)).frame(width: 4, height: 4)
                    }
                }
                .padding(.bottom, 3)
                RoundedRectangle(cornerRadius: 2).fill(Color(hex: colors.signal).opacity(0.25)).frame(height: 6)
                Capsule().fill(Color(hex: colors.lineStrong)).frame(width: 16, height: 3)
                Capsule().fill(Color(hex: colors.lineStrong)).frame(width: 12, height: 3)
                Spacer(minLength: 0)
            }
            .padding(6)
            .frame(width: 32)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(hex: colors.sidebar))

            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(Color(hex: colors.ink)).frame(width: 30, height: 4)
                Capsule().fill(Color(hex: colors.lineStrong)).frame(width: 44, height: 3)
                Capsule().fill(Color(hex: colors.lineStrong)).frame(width: 36, height: 3)
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Capsule().fill(Color(hex: colors.signal)).frame(width: 18, height: 7)
                }
            }
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(hex: colors.panel))
        }
    }
}

private struct PaletteThumbnail: View {
    let light: ThemePalette
    var dark: ThemePalette? = nil

    var body: some View {
        ZStack {
            MiniWindow(colors: light)
            if let dark {
                // Split diagonally, the way System Settings draws "Auto".
                MiniWindow(colors: dark)
                    .mask {
                        GeometryReader { proxy in
                            Path { path in
                                path.move(to: CGPoint(x: proxy.size.width * 0.62, y: 0))
                                path.addLine(to: CGPoint(x: proxy.size.width, y: 0))
                                path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height))
                                path.addLine(to: CGPoint(x: proxy.size.width * 0.38, y: proxy.size.height))
                                path.closeSubpath()
                            }
                        }
                    }
            }
        }
        .frame(width: 112, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.black.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        .accessibilityHidden(true)
    }
}

/// One choice in an appearance picker: thumbnail, a selection ring that sits
/// fully inside its own frame (never clipped), and a centered label.
private struct AppearanceChoice<Preview: View>: View {
    let title: String
    var subtitle: String? = nil
    let selected: Bool
    @ViewBuilder let preview: () -> Preview
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                preview()
                    .padding(4)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(selected ? OmilTheme.signal : .clear, lineWidth: 3)
                    }
                VStack(spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(OmilTheme.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(OmilFont.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(OmilMotion.quick, value: selected)
    }
}

/// A System Settings row: title with an explanatory subtitle, control on the trailing edge.
private struct SettingsRow<Accessory: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        LabeledContent {
            accessory()
        } label: {
            Text(title)
            Text(detail)
        }
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
        LabeledContent {
            Button(actionTitle, action: action)
                .buttonStyle(granted ? AnyPrimitiveButtonStyle(.bordered) : AnyPrimitiveButtonStyle(.borderedProminent))
        } label: {
            Label {
                Text(title)
                Text(detail)
            } icon: {
                Image(systemName: granted ? "checkmark.circle.fill" : icon)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(granted ? OmilTheme.mint : .secondary)
            }
        }
    }
}

private struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
