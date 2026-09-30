import AppKit
import Combine
import CoreImage
import SwiftUI
import OmilDesign
import OmilCore

// MARK: - Product shell

@MainActor
final class AppAppearance: ObservableObject {
    static let shared = AppAppearance()
    @Published private(set) var colorScheme: ColorScheme {
        didSet { palette = themePreset.palette(for: colorScheme) }
    }
    @Published var themePreset: ThemePreset = .graphite {
        didSet { palette = themePreset.palette(for: colorScheme) }
    }
    /// The active palette, resolved once per theme or appearance change.
    private(set) var palette: ThemePalette
    /// 0 = fully opaque window, 1 = fully clear. Persisted per user.
    @Published var windowTransparency: Double = UserDefaults.standard.object(forKey: "omil.windowTransparency") as? Double
        ?? AppAppearance.defaultTransparency {
        didSet { UserDefaults.standard.set(windowTransparency, forKey: "omil.windowTransparency") }
    }
    static let defaultTransparency = 0.4
    private var observation: NSKeyValueObservation?

    private init() {
        let scheme: ColorScheme = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        colorScheme = scheme
        palette = ThemePreset.graphite.palette(for: scheme)
        observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, change in
            let dark = change.newValue?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            Task { @MainActor [weak self] in self?.colorScheme = dark ? .dark : .light }
        }
    }

    func apply(_ preference: AppearancePreference) {
        switch preference {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        colorScheme = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
}

private struct AppAppearanceModifier: ViewModifier {
    let fullSizeTitlebar: Bool
    let hidesFullScreenToolbar: Bool
    @ObservedObject private var appearance = AppAppearance.shared

    func body(content: Content) -> some View {
        let palette = appearance.palette
        content.environment(\.colorScheme, appearance.colorScheme)
            .tint(Color(hex: palette.signal))
            .background(GlassBackdrop().ignoresSafeArea())
            .modifier(PointerAwareFocus())
            .background(WindowChrome(color: NSColor(hex: palette.canvas),
                                     appearance: appearance.colorScheme == .dark ? .darkAqua : .aqua,
                                     fullSizeTitlebar: fullSizeTitlebar,
                                     hidesFullScreenToolbar: hidesFullScreenToolbar))
    }
}

extension View {
    func omilAppearance(fullSizeTitlebar: Bool = false, hidesFullScreenToolbar: Bool = false) -> some View {
        modifier(AppAppearanceModifier(fullSizeTitlebar: fullSizeTitlebar,
                                       hidesFullScreenToolbar: hidesFullScreenToolbar))
    }

}

private struct WindowChrome: NSViewRepresentable {
    let color: NSColor
    let appearance: NSAppearance.Name
    let fullSizeTitlebar: Bool
    let hidesFullScreenToolbar: Bool

    func makeNSView(context: Context) -> WindowChromeView {
        let view = WindowChromeView()
        view.chromeColor = color
        view.chromeAppearance = appearance
        view.fullSizeTitlebar = fullSizeTitlebar
        view.hidesFullScreenToolbar = hidesFullScreenToolbar
        return view
    }

    func updateNSView(_ view: WindowChromeView, context: Context) {
        view.chromeColor = color
        view.chromeAppearance = appearance
        view.fullSizeTitlebar = fullSizeTitlebar
        view.hidesFullScreenToolbar = hidesFullScreenToolbar
    }
}

private final class WindowChromeView: NSView {
    private var fullScreenObservers: [NSObjectProtocol] = []
    var chromeColor: NSColor = .windowBackgroundColor {
        didSet { if !chromeColor.isEqual(oldValue) { updateWindow() } }
    }
    var chromeAppearance: NSAppearance.Name = .aqua {
        didSet { if chromeAppearance != oldValue { updateWindow() } }
    }
    var fullSizeTitlebar = false {
        didSet { if fullSizeTitlebar != oldValue { updateWindow() } }
    }
    var hidesFullScreenToolbar = false {
        didSet { if hidesFullScreenToolbar != oldValue { updateWindow() } }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fullScreenObservers.forEach(NotificationCenter.default.removeObserver)
        fullScreenObservers.removeAll()
        if let window {
            for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification,
                         NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                let observer = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        // Only windows that opt in hide their toolbar in full screen;
                        // the main window keeps its title, search, and controls.
                        if self.hidesFullScreenToolbar {
                            if name == NSWindow.willEnterFullScreenNotification {
                                self.window?.toolbar?.isVisible = false
                            } else if name == NSWindow.willExitFullScreenNotification {
                                self.window?.toolbar?.isVisible = true
                            }
                        }
                        self.updateWindow()
                    }
                }
                fullScreenObservers.append(observer)
            }
        }
        updateWindow()
    }

    deinit {
        MainActor.assumeIsolated {
            fullScreenObservers.forEach(NotificationCenter.default.removeObserver)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func updateWindow() {
        guard let window else { return }
        if fullSizeTitlebar && !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        if window.isOpaque { window.isOpaque = false }
        if !window.backgroundColor.isEqual(NSColor.clear) {
            window.backgroundColor = .clear
        }
        if window.appearance?.name != chromeAppearance {
            window.appearance = NSAppearance(named: chromeAppearance)
        }
        if window.styleMask.contains(.fullSizeContentView) {
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
            if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
        }
        if hidesFullScreenToolbar {
            let visible = !window.styleMask.contains(.fullScreen)
            if window.toolbar?.isVisible != visible { window.toolbar?.isVisible = visible }
        }
    }
}

/// Keep automatic button focus unobtrusive until the user navigates by keyboard.
private struct PointerAwareFocus: ViewModifier {
    @State private var keyboardNavigation = false

    func body(content: Content) -> some View {
        content
            .focusEffectDisabled(!keyboardNavigation)
            .background(FocusInputObserver(keyboardNavigation: $keyboardNavigation))
    }
}

private struct FocusInputObserver: NSViewRepresentable {
    @Binding var keyboardNavigation: Bool

    func makeNSView(context: Context) -> FocusInputView {
        let view = FocusInputView()
        view.onNavigationChange = { keyboardNavigation = $0 }
        return view
    }

    func updateNSView(_ view: FocusInputView, context: Context) {
        view.onNavigationChange = { keyboardNavigation = $0 }
    }

    static func dismantleNSView(_ view: FocusInputView, coordinator: ()) {
        view.stopObserving()
    }
}

private final class FocusInputView: NSView {
    var onNavigationChange: (Bool) -> Void = { _ in }
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.window else { return }
                if event.type == .leftMouseDown || event.type == .rightMouseDown {
                    self.onNavigationChange(false)
                } else if [48, 123, 124, 125, 126].contains(event.keyCode) {
                    self.onNavigationChange(true)
                }
            }
            return event
        }
    }

    func stopObserving() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

enum MainSection: String, Hashable, CaseIterable {
    case record, history, snippets, dictionary, styles, engine

    var title: String {
        switch self {
        case .record: return "Dictate"
        case .history: return "History"
        case .snippets: return "Snippets"
        case .dictionary: return "Dictionary"
        case .styles: return "Styles"
        case .engine: return "Engine"
        }
    }

    var icon: String {
        switch self {
        case .record: return "waveform"
        case .history: return "clock"
        case .snippets: return "text.quote"
        case .dictionary: return "character.book.closed"
        case .styles: return "textformat"
        case .engine: return "cpu"
        }
    }
}

struct RootView: View {
    let controller: DictationController
    @State private var onboarded: Bool

    init(controller: DictationController) {
        self.controller = controller
        _onboarded = State(initialValue: controller.onboarded)
    }

    /// Debug-only visual QA: `--args -OmilOnboardingStep 2` previews a setup
    /// page without changing the saved onboarding state.
    private var previewStep: Int? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-OmilOnboardingStep"), i + 1 < args.count { return Int(args[i + 1]) }
        #endif
        return nil
    }

    var body: some View {
        Group {
            if let previewStep {
                OnboardingView(controller: controller, initialStep: previewStep)
            } else if onboarded {
                MainWindowView(controller: controller)
            } else {
                OnboardingView(controller: controller)
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.9), value: onboarded)
        .frame(minWidth: 760, minHeight: 540)
        .omilAppearance(fullSizeTitlebar: true)
        .onReceive(controller.$onboarded.removeDuplicates()) { onboarded = $0 }
    }
}

/// Which main-window section is showing. Shared so menus, intents, and
/// Spotlight can route the window.
@MainActor
final class AppNavigation: ObservableObject {
    static let shared = AppNavigation()
    @Published var section: MainSection? = .record
}

struct MainWindowView: View {
    let controller: DictationController
    @ObservedObject private var appearance = AppAppearance.shared
    @ObservedObject private var navigation = AppNavigation.shared
    @Namespace private var sidebarSelection

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .navigationTitle((navigation.section ?? .record).title)
                .toastHost(bottomPadding: (navigation.section ?? .record) == .record ? 76 : 20)
        }
        .navigationSplitViewStyle(.balanced)
        .background {
            // ⌘1–⌘6 switch sections, like tabs in Apple's apps.
            ForEach(Array(MainSection.allCases.enumerated()), id: \.element) { index, item in
                Button(item.title) { withAnimation(OmilMotion.standard) { navigation.section = item } }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .hidden()
            }
        }
        .tint(OmilTheme.signal)
        .id("\(appearance.themePreset.id)-\(appearance.colorScheme)")
        #if DEBUG
        .task {
            // Visual QA hook: `open Omil.app --args -OmilPreviewToast -OmilSection engine`
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-OmilSection"), i + 1 < args.count,
               let section = MainSection(rawValue: args[i + 1]) {
                navigation.section = section
            }
            if args.contains("-OmilOpenSettings") {
                AppContext.appDelegate?.showSettings()
            }
            if args.contains("-OmilPreviewToast") {
                try? await Task.sleep(for: .seconds(1))
                ToastCenter.shared.show("Correction Deleted", symbol: "trash.fill") {}
            }
        }
        #endif
    }

    private var detail: some View {
        ZStack {
            page(navigation.section ?? .record)
                .id(navigation.section ?? .record)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 8)),
                    removal: .opacity
                ))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func page(_ section: MainSection) -> some View {
        Group {
            switch section {
            case .record: RecorderView(controller: controller, openEngine: { withAnimation(OmilMotion.standard) { navigation.section = .engine } })
            case .history: HistoryView(controller: controller)
            case .snippets: SnippetsView(controller: controller)
            case .dictionary: DictionaryView(controller: controller)
            case .styles: StylesView(controller: controller)
            case .engine: EngineView(controller: controller)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A native source list, grouped the way Apple's own apps group their sidebars.
    private var sidebar: some View {
        List {
            Section {
                sidebarRow(.record)
                sidebarRow(.history)
            }
            Section("Personalize") {
                sidebarRow(.snippets)
                sidebarRow(.dictionary)
                sidebarRow(.styles)
            }
            Section("System") {
                sidebarRow(.engine)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarEngineNotice(controller: controller) { navigation.section = .engine }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
    }

    private func sidebarRow(_ item: MainSection) -> some View {
        let selected = (navigation.section ?? .record) == item
        return ThemedSidebarRow(title: item.title, selected: selected, namespace: sidebarSelection) {
            Image(systemName: item.icon)
                .symbolRenderingMode(.hierarchical)
                .symbolVariant(selected ? .fill : .none)
                .foregroundStyle(selected ? OmilTheme.signal : OmilTheme.muted)
        } action: {
            withAnimation(OmilMotion.standard) { navigation.section = item }
        }
        .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
    }
}

// MARK: - Recorder

struct RecorderView: View {
    @ObservedObject var controller: DictationController
    var showsHeader = true
    var openEngine: (() -> Void)? = nil
    @State private var resultTab: ResultTab = .clean
    @State private var startedAt: Date?

    enum ResultTab: String, CaseIterable {
        case clean = "Transcript"
        case raw = "Original"
        case changes = "Changes"
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: OmilSpace.lg) {
                    RecorderStage(controller: controller, startedAt: startedAt, openEngine: openEngine)
                        .frame(minHeight: stageHeight(in: geometry.size.height))
                    if !controller.processingJobs.isEmpty {
                        PendingTranscriptionsCard(jobs: controller.processingJobs)
                            .transition(.opacity)
                    }
                    if hasResult {
                        ResultCard(controller: controller, selectedTab: $resultTab)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, showsHeader ? OmilSpace.xl : 0)
                .padding(.top, showsHeader ? 28 : 0)
                .padding(.bottom, showsHeader ? 96 : 0)
                .animation(OmilMotion.standard, value: hasResult)
                .animation(OmilMotion.standard, value: controller.processingJobs.count)
            }
            .scrollIndicators(.automatic)
            .overlay(alignment: .bottom) {
                if showsHeader {
                    ShortcutDock()
                        .padding(.bottom, 20)
                }
            }
        }
        .toolbar {
            if showsHeader {
                ToolbarItem(placement: .primaryAction) { ModePicker(controller: controller) }
            }
        }
        .onChange(of: controller.phase) { _, phase in
            if phase == .recording, startedAt == nil { startedAt = Date() }
            if phase != .recording { startedAt = nil }
            if phase == .ready { resultTab = .clean }
        }
    }

    /// Center the orb in the window until there's a result to show beneath it.
    private func stageHeight(in available: CGFloat) -> CGFloat {
        guard showsHeader else { return 320 }
        if hasResult || !controller.processingJobs.isEmpty { return 340 }
        return max(360, available - 140)
    }

    private var hasResult: Bool {
        !controller.lastCleaned.isEmpty || !controller.lastRaw.isEmpty || !controller.lastDiff.isEmpty
    }
}

/// A section header plus a filled group, matching Form's grouped sections so
/// Dictate reads as part of the same system as every other page.
private struct GroupedBox<Trailing: View, Content: View>: View {
    let title: String
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OmilTheme.ink)
                Spacer()
                trailing()
            }
            .padding(.horizontal, 10)
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(OmilTheme.groupFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private struct PendingTranscriptionsCard: View {
    let jobs: [DictationController.ProcessingJob]

    var body: some View {
        GroupedBox(title: jobs.count == 1 ? "In Progress" : "\(jobs.count) In Progress") {
            Text("You can record again")
                .font(OmilFont.caption)
                .foregroundStyle(.secondary)
        } content: {
            ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                if index > 0 { Divider().padding(.leading, 40) }
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small).frame(width: 18)
                    Text(jobs.count > 1 ? "Recording \(index + 1)" : "Recording")
                        .font(OmilFont.body)
                        .foregroundStyle(OmilTheme.ink)
                    Spacer()
                    Label(job.stage.title, systemImage: job.stage.icon)
                        .font(OmilFont.callout)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                        .animation(OmilMotion.standard, value: job.stage)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(jobs.count == 1 ? job.stage.title : "Recording \(index + 1), \(job.stage.title)")
            }
        }
        .animation(OmilMotion.standard, value: jobs.map(\.id))
    }
}

private struct RecorderStage: View {
    @ObservedObject var controller: DictationController
    let startedAt: Date?
    let openEngine: (() -> Void)?

    private var active: Bool { controller.phase == .recording }
    private var busy: Bool { controller.phase == .preparing || controller.phase == .processing }
    private var micReady: Bool { controller.micPermission == .granted }
    private var canRecord: Bool { micReady && controller.serverIsReady }

    var body: some View {
        VStack(spacing: 20) {
            StatusLabel(phase: controller.phase, environmentReady: canRecord)

            MeterReactive(meter: controller.audioMeter, enabled: active) { level in
                RecordButton(active: active, busy: busy, enabled: controller.serverIsReady && !busy, action: toggle)
                    .scaleEffect(1 + level * 0.08)
                    .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.7), value: level)
            }

            VStack(spacing: 6) {
                Group {
                    // Only the recording clock needs a per-second tick.
                    if active {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in statusTitle }
                    } else {
                        statusTitle
                    }
                }
                Text(secondaryStatus)
                    .font(OmilFont.body)
                    .foregroundStyle(OmilTheme.muted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: 420)
            }

            ZStack {
                if active {
                    LiveSignalRail(meter: controller.audioMeter)
                        .frame(width: 240, height: 28)
                        .transition(.scale(scale: 0.6, anchor: .center).combined(with: .opacity))
                } else if controller.phase == .processing {
                    ProcessingTrack(stage: controller.processingStage)
                        .frame(height: 28)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let setup = setupAction {
                    Button(setup.title, action: setup.action)
                        .omilButton(prominent: true)
                        .transition(.opacity)
                }
            }
            .frame(minHeight: 32)

            if active || controller.phase == .preparing {
                Button("Cancel") { controller.cancel() }
                    .omilButton()
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(OmilMotion.standard, value: controller.phase)
    }

    private var statusTitle: some View {
        Text(primaryStatus)
            .omilDisplay(small: true)
            .foregroundStyle(OmilTheme.ink)
            .monospacedDigit()
            .contentTransition(.numericText())
    }

    private var setupAction: (title: String, action: () -> Void)? {
        guard controller.phase == .idle || controller.phase == .failed || controller.phase == .ready else { return nil }
        if !micReady {
            return (controller.micPermission == .denied ? "Open Microphone Settings" : "Allow Microphone", { controller.requestMic() })
        }
        if !controller.serverIsReady, let openEngine {
            return ("Open Engine", openEngine)
        }
        return nil
    }

    private var primaryStatus: String {
        switch controller.phase {
        case .idle:
            if !micReady { return "Microphone access needed" }
            if !controller.serverIsReady { return "Speech setup needed" }
            return "Ready when you are"
        case .preparing: return "Getting ready"
        case .recording:
            guard let startedAt else { return "Listening" }
            return clockLabel(Date().timeIntervalSince(startedAt))
        case .processing: return controller.processingStage.title
        case .ready:
            if controller.processingJobs.count == 1 { return controller.processingJobs[0].stage.title }
            if controller.processingJobs.count > 1 { return "\(controller.processingJobs.count) processing" }
            return controller.lastCleaned.isEmpty ? "Nothing heard" : "Done"
        case .failed: return "Something went wrong"
        }
    }

    private var secondaryStatus: String {
        switch controller.phase {
        case .idle:
            if !micReady { return "Omil only listens while you dictate." }
            if !controller.serverIsReady { return "Download or start a speech model to begin." }
            return "Click to dictate into the app you were using, or use a shortcut from anywhere."
        case .recording:
            return controller.draftText.isEmpty ? "Listening for your voice" : controller.draftText
        case .ready where !controller.processingJobs.isEmpty:
            return "Ready for another recording while these finish."
        default:
            return controller.statusMessage
        }
    }

    private func toggle() {
        if !micReady { controller.requestMic(); return }
        active ? controller.stop() : controller.start()
    }
}

private struct RecordButton: View {
    let active: Bool
    let busy: Bool
    let enabled: Bool
    let action: () -> Void
    @State private var hovered = false
    @State private var pulse = false

    private var tint: Color { active ? OmilTheme.coral : OmilTheme.signal }
    private var iconColor: Color { active ? .white : OmilTheme.signalInk }
    /// A soft glow suits dark mode; in light mode only a live recording glows.
    private var glowOpacity: Double {
        if active { return 0.4 }
        return GlassLook.isDark ? (hovered ? 0.35 : 0.24) : 0
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                // Ambient light the orb casts onto the glass behind it.
                // A radial gradient reads the same as a blurred circle at a
                // fraction of the per-frame cost.
                Circle()
                    .fill(RadialGradient(colors: [tint.opacity(glowOpacity), .clear],
                                         center: .center, startRadius: 30, endRadius: 80))
                    .frame(width: 160, height: 160)
                    .scaleEffect(active && pulse ? 1.18 : 1)

                Circle()
                    .fill(.clear)
                    .frame(width: 88, height: 88)
                    .liquidGlass(in: Circle(), tint: tint, interactive: true)

                if busy {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(iconColor)
                } else {
                    Image(systemName: active ? "stop.fill" : "mic.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(iconColor)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 128, height: 128)
            .scaleEffect(hovered && enabled ? 1.04 : 1)
            .opacity(enabled || active ? 1 : 0.5)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!(enabled || active))
        .onHover { hovered = $0 }
        .animation(OmilMotion.standard, value: hovered)
        .animation(OmilMotion.standard, value: active)
        .onChange(of: active) { _, isActive in
            pulse = false
            guard isActive else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityLabel(active ? "Stop recording" : "Start recording")
    }
}

/// Feeds the latest microphone level to its content while enabled, so only this
/// small subtree redraws on every meter tick.
private struct MeterReactive<Content: View>: View {
    @ObservedObject var meter: AudioMeter
    let enabled: Bool
    @ViewBuilder let content: (Double) -> Content

    var body: some View {
        content(enabled ? min(1, max(0, meter.levels.last ?? 0)) : 0)
    }
}

/// Keyboard shortcuts, docked as a floating glass capsule.
private struct ShortcutDock: View {
    @ObservedObject private var hotkeys = HotkeyManager.shared

    var body: some View {
        HStack(spacing: 18) {
            ShortcutHint(key: hotkeys.pushToTalkName, label: "Hold to talk")
            if hotkeys.toggleEnabled {
                ShortcutHint(key: HotkeyManager.toggleShortcutSymbol, label: "Start or stop")
            }
            ShortcutHint(key: "esc", label: "Cancel")
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .liquidGlass(in: Capsule())
    }
}

private struct ShortcutHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 7) {
            KeyCap(text: key)
            Text(label)
                .font(OmilFont.callout)
                .foregroundStyle(OmilTheme.muted)
        }
    }
}

private struct ResultCard: View {
    @ObservedObject var controller: DictationController
    @Binding var selectedTab: RecorderView.ResultTab

    var body: some View {
        GroupedBox(title: "Last Transcript") {
            SegmentedTabs(
                options: RecorderView.ResultTab.allCases,
                selection: $selectedTab,
                label: { $0.rawValue }
            )
        } content: {
            ScrollView {
                Text(resultText)
                    .font(selectedTab == .changes ? OmilFont.mono : OmilFont.reading)
                    .lineSpacing(4)
                    .foregroundStyle(isEmpty ? OmilTheme.faint : OmilTheme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .contentTransition(.opacity)
                    .animation(OmilMotion.standard, value: resultText)
            }
            .frame(minHeight: 96, maxHeight: 220)

            Divider().padding(.horizontal, 12)

            HStack(spacing: 6) {
                if !controller.lastDeliveryMethod.isEmpty {
                    Image(systemName: deliverySucceeded ? "checkmark.circle.fill" : "info.circle.fill")
                        .foregroundStyle(deliverySucceeded ? OmilTheme.mint : OmilTheme.warning)
                    Text(controller.lastDeliveryMethod)
                        .lineLimit(1)
                }
                Spacer()
                if !controller.lastCleaned.isEmpty {
                    IconAction(icon: "arrow.uturn.backward", label: "Undo Insertion", disabled: !controller.canUndo) {
                        controller.undoLast()
                    }
                    IconAction(icon: "doc.on.doc", label: "Copy") {
                        controller.copyLast()
                        ToastCenter.shared.show("Copied to Clipboard", symbol: "doc.on.doc.fill")
                    }
                }
            }
            .font(OmilFont.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
        }
    }

    private var isEmpty: Bool {
        switch selectedTab {
        case .clean: return controller.lastCleaned.isEmpty
        case .raw: return controller.lastRaw.isEmpty
        case .changes: return controller.lastDiff.isEmpty
        }
    }

    private var deliverySucceeded: Bool {
        controller.lastDeliveryMethod.hasPrefix("Inserted into") ||
        controller.lastDeliveryMethod.hasPrefix("Pasted into")
    }

    private var resultText: String {
        switch selectedTab {
        case .clean: return controller.lastCleaned.isEmpty ? "Your transcript will appear here." : controller.lastCleaned
        case .raw: return controller.lastRaw.isEmpty ? "The unedited transcript will appear here." : controller.lastRaw
        case .changes: return controller.lastDiff.isEmpty ? "Edits to your original transcript will appear here." : controller.lastDiff
        }
    }
}

// MARK: - Page layout
//
// Every secondary page is a native grouped Form. The system owns insets, row
// height, section spacing, and alignment, so all pages line up with each other
// and with Settings. Titles live in the toolbar; counts go in the subtitle.

extension View {
    func omilPage(subtitle: String? = nil) -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .navigationSubtitle(subtitle ?? "")
    }
}

/// Title + secondary line, the standard two-line row label.
private struct RowLabel: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil

    var body: some View {
        if let symbol {
            Label {
                labelText
            } icon: {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
        } else {
            labelText
        }
    }

    @ViewBuilder private var labelText: some View {
        Text(title)
        if let subtitle, !subtitle.isEmpty { Text(subtitle) }
    }
}

/// A borderless icon button used for trailing row actions.
/// The trailing "more" menu used by every list row.
private struct RowMenu<Items: View>: View {
    @ViewBuilder let items: () -> Items
    @State private var hovered = false

    var body: some View {
        Menu { items() } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(hovered ? OmilTheme.ink : OmilTheme.muted)
                .frame(width: 28, height: 28)
                .background(Circle().fill(hovered ? OmilTheme.ink.opacity(0.08) : .clear))
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovered = $0 }
        .animation(OmilMotion.quick, value: hovered)
        .help("More")
        .accessibilityLabel("More actions")
    }
}

private struct RowAction: View {
    let symbol: String
    let label: String
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(IconButtonStyle(destructive: role == .destructive))
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - History

struct HistoryView: View {
    @ObservedObject var controller: DictationController
    @State private var search = ""
    @StateObject private var feed = HistoryFeed()
    @State private var confirmDelete: DictationController.HistoryEntry?
    @State private var confirmRecoveryDelete: RecoveryRecording?
    @State private var selectedTranscript: HistoryTranscript?
    @State private var dataRevision = 0
    @State private var lastQuery = ""

    private struct Request: Hashable {
        let search: String
        let revision: Int
    }

    private var isBusy: Bool {
        controller.phase == .recording || controller.phase == .preparing || controller.phase == .processing
    }

    private var itemCountLabel: String {
        let count = feed.totalCount
        return count == 1 ? "1 item" : "\(count) items"
    }

    var body: some View {
        Group {
            if controller.history.isEmpty && controller.recoveryRecordings.isEmpty {
                EmptyState(
                    icon: "waveform.badge.mic",
                    title: "No History Yet",
                    detail: "Your transcripts and saved recordings will appear here."
                )
            } else if !feed.hasLoaded || (feed.isLoading && feed.rows.isEmpty) {
                ProgressView("Loading History…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if feed.rows.isEmpty {
                EmptyState(icon: "magnifyingglass", title: "No Results", detail: "Try a shorter word or phrase.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(feed.rows) { row in
                            switch row {
                            case .savedHeader, .dayHeader:
                                sectionHeader(row)
                                    .font(OmilFont.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 12)
                                    .padding(.horizontal, 4)
                            case .recording, .transcript:
                                historyRow(row)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(OmilTheme.groupFill, in: RoundedRectangle(cornerRadius: 12))
                                    .onAppear {
                                        guard row.id == feed.rows.last?.id else { return }
                                        Task { await feed.loadMore() }
                                    }
                            }
                        }
                        if feed.hasMore {
                            Button {
                                Task { await feed.loadMore() }
                            } label: {
                                HStack(spacing: 8) {
                                    if feed.isLoadingMore { ProgressView().controlSize(.small) }
                                    Text(feed.isLoadingMore ? "Loading…" : "Load More")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .disabled(feed.isLoading || feed.isLoadingMore)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .frame(maxWidth: 920)
                    .frame(maxWidth: .infinity)
                }
                .id(lastQuery)
                .omilPage(subtitle: itemCountLabel)
            }
        }
        .overlay(alignment: .topTrailing) {
            if feed.isLoading && !feed.rows.isEmpty {
                ProgressView().controlSize(.small).padding(12)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle("Keep History", isOn: Binding(
                        get: { controller.historyEnabled },
                        set: { controller.setHistoryEnabled($0) }
                    ))
                } label: {
                    Label("History Options", systemImage: "ellipsis.circle")
                }
                .help("History options")
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search Dictations")
        .task(id: Request(search: search, revision: dataRevision)) {
            let sameQuery = search == lastQuery
            if !sameQuery {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            lastQuery = search
            await feed.reload(recordings: controller.recoveryRecordings, history: controller.history,
                              search: search, preserveLoadedCount: sameQuery)
        }
        .onReceive(controller.$history.dropFirst()) { _ in dataRevision += 1 }
        .onReceive(controller.$recoveryRecordings.dropFirst()) { _ in dataRevision += 1 }
        .onDisappear { controller.recoveryPlayback.stop() }
        .sheet(item: $selectedTranscript) { transcript in
            HistoryTranscriptSheet(transcript: transcript)
        }
        .confirmationDialog(
            "Delete this dictation?",
            isPresented: Binding(
                get: { confirmDelete != nil },
                set: { if !$0 { confirmDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let entry = confirmDelete {
                    withAnimation(OmilMotion.standard) { controller.deleteHistoryEntry(entry) }
                    ToastCenter.shared.show("Dictation Deleted", symbol: "trash.fill")
                }
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("This removes the transcript from this Mac.")
        }
        .confirmationDialog(
            "Delete this saved recording?",
            isPresented: Binding(
                get: { confirmRecoveryDelete != nil },
                set: { if !$0 { confirmRecoveryDelete = nil } }
            )
        ) {
            Button("Delete Recording", role: .destructive) {
                if let recording = confirmRecoveryDelete {
                    withAnimation(OmilMotion.standard) { controller.deleteRecovery(recording) }
                    ToastCenter.shared.show("Recording Deleted", symbol: "trash.fill")
                }
                confirmRecoveryDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmRecoveryDelete = nil }
        } message: {
            Text("This permanently deletes the recording. Your transcript stays in History.")
        }
    }

    @ViewBuilder
    private func sectionHeader(_ header: HistoryListRow) -> some View {
        switch header {
        case .dayHeader(let day):
            Text(controller.dayLabel(for: day))
        default:
            HStack {
                Text("Saved Recordings")
                Spacer()
                Text(controller.audioRetentionDays == 1 ? "Kept for 1 day" : "Kept for \(controller.audioRetentionDays) days")
                    .fontWeight(.regular)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func historyRow(_ row: HistoryListRow) -> some View {
        switch row {
        case .recording(let recording):
            RecoveryRecordingRow(
                recording: recording,
                preview: feed.display[row.id]?.preview ?? "",
                playback: controller.recoveryPlayback,
                isBusy: isBusy,
                play: { controller.playRecovery(recording) },
                seek: { controller.seekRecovery(recording, to: $0) },
                retry: {
                    controller.retryRecovery(recording)
                    ToastCenter.shared.show("Transcribing Again", symbol: "arrow.clockwise.circle.fill")
                },
                copy: { copy(recording.transcript ?? "") },
                viewTranscript: { selectedTranscript = transcript(for: recording) },
                delete: { confirmRecoveryDelete = recording }
            )
            .equatable()
        case .transcript(let entry):
            HistoryRow(
                entry: entry,
                preview: feed.display[row.id]?.preview ?? "",
                wordCount: feed.display[row.id]?.wordCount ?? 0,
                copy: { copy(entry.cleaned) },
                viewTranscript: { selectedTranscript = HistoryTranscript(entry: entry) },
                delete: { confirmDelete = entry }
            )
            .equatable()
        case .savedHeader, .dayHeader:
            EmptyView()
        }
    }

    private func copy(_ text: String) {
        ToastCenter.shared.copy(text)
    }

    private func transcript(for recording: RecoveryRecording) -> HistoryTranscript {
        let clean = recording.transcript ?? ""
        let candidates = controller.history.filter {
            $0.cleaned == clean && abs($0.duration - recording.duration) < 2 &&
            $0.date >= recording.createdAt.addingTimeInterval(-60) &&
            $0.date <= recording.createdAt.addingTimeInterval(3_600)
        }
        let raw = recording.rawTranscript ?? (candidates.count == 1 ? candidates[0].raw : nil)
        return HistoryTranscript(id: recording.id, title: recording.createdAt.formatted(date: .abbreviated, time: .shortened), raw: raw, clean: clean)
    }
}

private struct HistoryTranscript: Identifiable {
    let id: UUID
    let title: String
    let raw: String?
    let clean: String

    init(id: UUID, title: String, raw: String?, clean: String) {
        self.id = id
        self.title = title
        self.raw = raw
        self.clean = clean
    }

    init(entry: DictationController.HistoryEntry) {
        self.init(id: entry.id, title: entry.date.formatted(date: .abbreviated, time: .shortened), raw: entry.raw, clean: entry.cleaned)
    }
}

private struct HistoryTranscriptSheet: View {
    let transcript: HistoryTranscript
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 2
    @State private var copied = false
    @State private var diff: String?

    private var displayedText: String {
        switch tab {
        case 0: return transcript.raw ?? "The original transcript isn't available for this older recording."
        case 1:
            guard transcript.raw != nil else { return "Changes aren't available for this older recording." }
            return diff ?? ""
        default: return transcript.clean
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(displayedText)
                    .font(tab == 1 ? OmilFont.mono : OmilFont.reading)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .navigationTitle("Transcript")
            .navigationSubtitle(transcript.title)
            .task(id: tab) {
                guard tab == 1, diff == nil, let raw = transcript.raw else { return }
                let clean = transcript.clean
                diff = await Task.detached(priority: .userInitiated) { DiffUtil.diff(raw: raw, cleaned: clean) }.value
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Version", selection: $tab) {
                        Text("Clean").tag(2)
                        Text("Original").tag(0)
                        Text("Changes").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(displayedText, forType: .string)
                        withAnimation(OmilMotion.quick) { copied = true }
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.5))
                            withAnimation(OmilMotion.quick) { copied = false }
                        }
                    }
                    .contentTransition(.symbolEffect(.replace))
                    .disabled(tab != 2 && transcript.raw == nil)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(width: 620, height: 480)
        .omilAppearance()
    }
}

private struct RecoveryRecordingRow: View, Equatable {
    let recording: RecoveryRecording
    let preview: String
    /// Not observed here: only the play button and the controls of the
    /// playing row subscribe, so playback progress doesn't redraw every row.
    let playback: RecoveryPlayback
    let isBusy: Bool
    let play: () -> Void
    let seek: (TimeInterval) -> Void
    let retry: () -> Void
    let copy: () -> Void
    let viewTranscript: () -> Void
    let delete: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.recording == rhs.recording && lhs.preview == rhs.preview &&
        lhs.isBusy == rhs.isBusy && lhs.playback === rhs.playback
    }

    private var stateLabel: String {
        switch recording.state {
        case .pending: return "Processing"
        case .ready: return "Ready"
        case .failed: return "Retry available"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                RecoveryPlayButton(playback: playback, recordingID: recording.id, isBusy: isBusy, action: play)

                VStack(alignment: .leading, spacing: 2) {
                    Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                    Text("\(clockLabel(recording.duration)) · \(stateLabel)")
                        .font(OmilFont.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                menu
            }

            RecoveryPlaybackControls(playback: playback, recordingID: recording.id, seek: seek)

            if let transcript = recording.transcript, !transcript.isEmpty {
                Text(preview)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else if let failure = recording.failureReason, !failure.isEmpty {
                Text(failure)
                    .font(OmilFont.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contextMenu { menuItems }
    }

    private var menu: some View {
        RowMenu { menuItems }
    }

    @ViewBuilder private var menuItems: some View {
        Button("Transcribe Again", systemImage: "arrow.clockwise", action: retry)
            .disabled(isBusy)
        if recording.transcript?.isEmpty == false {
            Button("View Transcript", systemImage: "text.alignleft", action: viewTranscript)
            Button("Copy Transcript", systemImage: "doc.on.doc", action: copy)
        }
        Divider()
        Button("Delete Recording", systemImage: "trash", role: .destructive, action: delete)
    }
}

private struct RecoveryPlayButton: View {
    @ObservedObject var playback: RecoveryPlayback
    let recordingID: UUID
    let isBusy: Bool
    let action: () -> Void

    private var isPlaying: Bool { playback.recordingID == recordingID && playback.isPlaying }

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 11, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
                .liquidGlass(in: Circle(), interactive: !isBusy)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .help(isPlaying ? "Pause" : "Play")
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}

private struct RecoveryPlaybackControls: View {
    @ObservedObject var playback: RecoveryPlayback
    let recordingID: UUID
    let seek: (TimeInterval) -> Void

    var body: some View {
        if playback.recordingID == recordingID {
            if let error = playback.errorMessage {
                Text(error)
                    .font(OmilFont.callout)
                    .foregroundStyle(OmilTheme.warning)
            } else {
                HStack(spacing: 10) {
                    Text(clockLabel(playback.position)).monospacedDigit()
                    Slider(value: Binding(get: { playback.position }, set: { seek($0) }),
                           in: 0...max(playback.duration, 0.01))
                        .controlSize(.small)
                        .accessibilityLabel("Playback position")
                    Text(clockLabel(playback.duration)).monospacedDigit()
                    Menu("\(playback.rate.formatted())×") {
                        ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { rate in
                            Button("\(rate.formatted())×") { playback.rate = rate }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Playback speed")
                }
                .font(OmilFont.caption)
                .foregroundStyle(.secondary)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// "m:ss" for durations and playback positions.
func clockLabel(_ time: TimeInterval) -> String {
    let seconds = max(0, Int(time))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

private struct HistoryRow: View, Equatable {
    let entry: DictationController.HistoryEntry
    let preview: String
    let wordCount: Int
    let copy: () -> Void
    let viewTranscript: () -> Void
    let delete: () -> Void
    @State private var expanded = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry && lhs.preview == rhs.preview && lhs.wordCount == rhs.wordCount
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(expanded ? entry.cleaned : preview)
                    .lineLimit(expanded ? nil : 2)
                    .textSelection(.enabled)
                Text("\(entry.date.formatted(date: .omitted, time: .shortened)) · \(wordCount) words")
                    .font(OmilFont.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(OmilMotion.standard) { expanded.toggle() } }

            RowAction(symbol: "doc.on.doc", label: "Copy", action: copy)
            RowMenu { menuItems }
        }
        .padding(.vertical, 4)
        .contextMenu { menuItems }
        .accessibilityAction(named: expanded ? "Collapse" : "Expand") { expanded.toggle() }
    }

    @ViewBuilder private var menuItems: some View {
        Button("Copy", systemImage: "doc.on.doc", action: copy)
        Button("View Original and Changes", systemImage: "text.alignleft", action: viewTranscript)
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive, action: delete)
    }
}

// MARK: - Snippets

struct SnippetsView: View {
    @ObservedObject var controller: DictationController
    @State private var trigger = ""
    @State private var expansion = ""
    @State private var validationMessage = ""
    @FocusState private var triggerFocused: Bool

    var body: some View {
        Form {
            Section {
                TextField("When I say", text: $trigger, prompt: Text("my intro"))
                    .focused($triggerFocused)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Write this")
                    TextField("Write this", text: $expansion, prompt: Text("The text Omil should insert"), axis: .vertical)
                        .labelsHidden()
                        .lineLimit(3...8)
                        .multilineTextAlignment(.leading)
                        .textFieldStyle(.plain)
                        .padding(8)
                        .background(OmilTheme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .padding(.vertical, 2)
            } header: {
                Text("New Snippet")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text(validationMessage.isEmpty ? "Say the phrase on its own or inside a sentence." : validationMessage)
                        .foregroundStyle(validationMessage.isEmpty ? .secondary : OmilTheme.warning)
                    Spacer()
                    Button("Add Snippet") { addSnippet() }
                        .omilButton(prominent: true)
                        .disabled(trigger.trimmed.isEmpty || expansion.trimmed.isEmpty || trigger.count > 60 || expansion.count > 4_000)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }

            Section("Saved Snippets") {
                if controller.snippets.isEmpty {
                    Text("Save an address, sign-off, or introduction, then give it a short spoken phrase.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.snippets) { snippet in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("“\(snippet.trigger)”")
                                    .fontWeight(.medium)
                                Text(snippet.expansion)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            RowAction(symbol: "trash", label: "Delete Snippet", role: .destructive) {
                                delete(snippet)
                            }
                        }
                        .padding(.vertical, 2)
                        .contextMenu {
                            Button("Copy Text", systemImage: "doc.on.doc") { ToastCenter.shared.copy(snippet.expansion) }
                            Divider()
                            Button("Delete Snippet", systemImage: "trash", role: .destructive) { delete(snippet) }
                        }
                    }
                }
            }
        }
        .omilPage(subtitle: controller.snippets.count == 1 ? "1 snippet" : "\(controller.snippets.count) snippets")
    }

    private func addSnippet() {
        var error: String?
        let newTrigger = trigger
        let newExpansion = expansion
        withAnimation(OmilMotion.standard) {
            error = controller.addSnippet(trigger: newTrigger, expansion: newExpansion)
        }
        if let error {
            validationMessage = error
            NSSound.beep()
            return
        }
        trigger = ""
        expansion = ""
        validationMessage = ""
        ToastCenter.shared.show("Snippet Added")
        triggerFocused = true
    }

    private func delete(_ snippet: DictationController.Snippet) {
        let trigger = snippet.trigger
        let expansion = snippet.expansion
        withAnimation(OmilMotion.standard) { controller.deleteSnippet(snippet) }
        ToastCenter.shared.show("Snippet Deleted", symbol: "trash.fill") { [controller] in
            withAnimation(OmilMotion.standard) { _ = controller.addSnippet(trigger: trigger, expansion: expansion) }
        }
    }
}

// MARK: - Styles

struct StylesView: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        Form {
            Section {
                ForEach(DictationController.AppCategory.allCases) { category in
                    Picker(selection: Binding(
                        get: { controller.style(for: category) },
                        set: { controller.setStyle($0, for: category) }
                    )) {
                        ForEach(styles(for: category), id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    } label: {
                        Label {
                            Text(category.rawValue)
                            Text(appExamples(for: category))
                        } icon: {
                            Image(systemName: category.icon)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Writing Style by App")
            } footer: {
                Text("Omil adjusts punctuation and capitalization to fit where you're writing.")
            }

            Section("Preview") {
                ForEach(DictationController.AppCategory.allCases) { category in
                    LabeledContent(category.rawValue) {
                        Text(preview(for: controller.style(for: category)))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .omilPage()
    }

    private func styles(for category: DictationController.AppCategory) -> [WritingStyle] {
        WritingStyle.allCases.filter { style in
            category == .personal ? style != .excited : style != .veryCasual
        }
    }

    private func appExamples(for category: DictationController.AppCategory) -> String {
        switch category {
        case .personal: return "Messages, WhatsApp, Signal"
        case .work: return "Slack, Teams, Notion"
        case .email: return "Mail, Outlook, Superhuman"
        case .other: return "Documents and everything else"
        }
    }

    private func preview(for style: WritingStyle) -> String {
        switch style {
        case .automatic: return "I can send the draft by Friday."
        case .formal: return "I can send the draft by Friday."
        case .casual: return "I can send the draft by Friday"
        case .veryCasual: return "i can send the draft by Friday"
        case .excited: return "I can send the draft by Friday!"
        }
    }
}

// MARK: - Dictionary

struct DictionaryView: View {
    @ObservedObject var controller: DictationController
    @State private var spoken = ""
    @State private var written = ""
    @FocusState private var focusedField: Field?

    private enum Field { case spoken, written }

    var body: some View {
        let keys = controller.dictionaryEntries.keys.sorted()
        Form {
            Section {
                TextField("When I say", text: $spoken, prompt: Text("oh mill"))
                    .focused($focusedField, equals: .spoken)
                    .onSubmit { focusedField = .written }
                TextField("Write instead", text: $written, prompt: Text("Omil"))
                    .focused($focusedField, equals: .written)
                    .onSubmit(addWord)
            } header: {
                Text("New Correction")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Use this for names and words Omil mishears.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Correction") { addWord() }
                        .omilButton(prominent: true)
                        .disabled(spoken.trimmed.isEmpty || written.trimmed.isEmpty)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }

            Section("Corrections") {
                if keys.isEmpty {
                    Text("No corrections yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(keys, id: \.self) { key in
                        HStack(spacing: 10) {
                            Text(key)
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            Text(controller.dictionaryEntries[key] ?? "")
                                .fontWeight(.medium)
                            Spacer()
                            RowAction(symbol: "trash", label: "Delete Correction", role: .destructive) {
                                delete(key)
                            }
                        }
                        .contextMenu {
                            Button("Delete Correction", systemImage: "trash", role: .destructive) {
                                delete(key)
                            }
                        }
                    }
                }
            }
        }
        .omilPage(subtitle: keys.count == 1 ? "1 correction" : "\(keys.count) corrections")
    }

    private func addWord() {
        let source = spoken.trimmed
        let replacement = written.trimmed
        guard !source.isEmpty, !replacement.isEmpty else { return }
        focusedField = nil
        spoken = ""
        written = ""
        withAnimation(OmilMotion.standard) { controller.confirmDictionary(spoken: source, written: replacement) }
        ToastCenter.shared.show("Correction Added")
        focusedField = .spoken
    }

    private func delete(_ key: String) {
        let written = controller.dictionaryEntries[key] ?? ""
        withAnimation(OmilMotion.standard) { controller.deleteDictionaryEntry(spoken: key) }
        ToastCenter.shared.show("Correction Deleted", symbol: "trash.fill") { [controller] in
            withAnimation(OmilMotion.standard) { controller.confirmDictionary(spoken: key, written: written) }
        }
    }
}

// MARK: - Engine

private struct ModelOption {
    var file: String
    var name: String
    var size: String
}

private let whisperModelOptions = [
    ModelOption(file: "ggml-base-q8_0.bin", name: "Whisper base Q8 · compact", size: "82 MB"),
    ModelOption(file: "ggml-small-q8_0.bin", name: "Whisper small Q8 · faster", size: "264 MB"),
    ModelOption(file: "ggml-medium-q8_0.bin", name: "Whisper medium Q8", size: "823 MB"),
    ModelOption(file: "ggml-large-v3-turbo-q8_0.bin", name: "Whisper large-v3 turbo Q8", size: "874 MB"),
    ModelOption(file: "ggml-large-v3-q5_0.bin", name: "Whisper large-v3 Q5", size: "1.1 GB"),
    ModelOption(file: "ggml-distil-large-v3.bin", name: "Distil-Whisper large-v3 · English only", size: "1.5 GB"),
]

private let rewriteModelOptions = [
    ModelOption(file: "Qwen3.5-0.8B-Q4_K_M.gguf", name: "Qwen3.5 0.8B", size: "533 MB"),
    ModelOption(file: "Qwen3.5-2B-Q4_K_M.gguf", name: "Qwen3.5 2B", size: "1.3 GB"),
    ModelOption(file: "Qwen3.5-4B-Q4_K_M.gguf", name: "Qwen3.5 4B", size: "2.7 GB"),
    ModelOption(file: "Qwen3.5-9B-Q4_K_M.gguf", name: "Qwen3.5 9B", size: "5.7 GB"),
    ModelOption(file: "Llama-3.1-8B-Instruct-Q4_K_M.gguf", name: "Llama 3.1 8B Instruct", size: "4.9 GB"),
    ModelOption(file: "gemma-3-4b-it-Q4_K_M.gguf", name: "Gemma 3 4B Instruct", size: "2.5 GB"),
]

struct EngineView: View {
    @ObservedObject var controller: DictationController
    @State private var modelPendingDeletion: ModelOption?
    @State private var confirmTokenRotation = false
    @State private var showsAllModels = false
    @State private var showsOtherServer = false
    @State private var checking = false

    private var healthy: Bool { controller.serverIsReady }
    private var preparing: Bool {
        controller.modelsPreparing
            || !controller.downloadingModelIDs.isEmpty
            || controller.serverHealth.localizedCaseInsensitiveContains("starting")
            || controller.serverHealth.localizedCaseInsensitiveContains("restarting")
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button {
                        checkNow()
                    } label: {
                        if checking {
                            ProgressView().controlSize(.small).frame(width: 64)
                        } else {
                            Text("Check Now")
                        }
                    }
                    .omilButton()
                    .disabled(checking)
                } label: {
                    Label {
                        Text(healthy ? "Ready for Dictation" : preparing ? "Preparing Models" : "Setup Needed")
                        Text(controller.speechSetupSummary)
                    } icon: {
                        Image(systemName: healthy ? "checkmark.circle.fill" : preparing ? "arrow.triangle.2.circlepath.circle.fill" : "exclamationmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(healthy ? OmilTheme.mint : preparing ? Color.secondary : OmilTheme.warning)
                    }
                }
                installStatus
            }

            Section {
                ModelChoiceRow(
                    stage: "Transcription",
                    detail: "Turns speech into text",
                    symbol: "waveform",
                    selection: Binding(
                        get: { controller.displayedWhisperFile },
                        set: { controller.chooseWhisperModel(file: $0) }
                    ),
                    activeFile: controller.whisperFile,
                    options: whisperModelOptions,
                    controller: controller
                )
                ModelChoiceRow(
                    stage: "Cleanup",
                    detail: "Removes filler words and fixes punctuation",
                    symbol: "wand.and.stars",
                    selection: Binding(
                        get: { controller.displayedLLMFile },
                        set: { controller.chooseLLMModel(file: $0) }
                    ),
                    activeFile: controller.llmFile,
                    options: rewriteModelOptions,
                    controller: controller
                )
            } header: {
                Text("Models in Use")
            }

            ModelLibrarySections(controller: controller, showsAll: showsAllModels) { modelPendingDeletion = $0 }

            LANSharingSection(controller: controller, confirmTokenRotation: $confirmTokenRotation)

            Section {
                DisclosureGroup(isExpanded: $showsOtherServer) {
                    TextField("Host", text: $controller.externalServerConfig.host, prompt: Text("192.168.1.20"))
                    TextField("Port", value: $controller.externalServerConfig.port, format: .number.grouping(.never), prompt: Text("3217"))
                    SecureField("Server Token", text: $controller.externalServerConfig.token, prompt: Text("Token from the other server"))
                    HStack {
                        Spacer()
                        if controller.usesCustomServer {
                            Button("Use This Mac") { controller.useManagedServer() }
                                .omilButton()
                        }
                        Button(controller.usesCustomServer ? "Update Server" : "Use This Server") {
                            controller.saveServerConfig()
                            ToastCenter.shared.show("Connecting to Server", symbol: "network")
                        }
                        .omilButton(prominent: true)
                    }
                } label: {
                    LabeledContent {
                        Text(verbatim: "\(controller.serverConfig.host):\(controller.serverConfig.port)")
                            .font(OmilFont.mono)
                            .foregroundStyle(.secondary)
                    } label: {
                        RowLabel(
                            title: "Connect to Another Server",
                            subtitle: controller.usesCustomServer ? "Active" : "Audio and text go to the address you enter.",
                            symbol: controller.usesCustomServer ? "network" : "macbook"
                        )
                    }
                }
            } header: {
                Text("Advanced")
            } footer: {
                if !controller.serverOpNote.isEmpty || !controller.serverNote.isEmpty {
                    Text(controller.serverOpNote.isEmpty ? controller.serverNote : controller.serverOpNote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .omilPage(subtitle: healthy ? "Ready" : preparing ? "Preparing" : "Setup needed")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Show", selection: $showsAllModels) {
                    Text("Installed").tag(false)
                    Text("All Models").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Show installed models or every available model")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if ["loading", "ready", "inUse", "unloading"].contains(controller.selectedLLMMemoryState) {
                        Button(controller.selectedLLMMemoryState == "inUse" ? "Release Memory After Use" : "Free Memory") {
                            controller.unloadModels()
                        }
                        .disabled(controller.selectedLLMMemoryState == "unloading")
                    }
                    if controller.modelIsDownloaded(file: controller.llmFile) == true {
                        Button(controller.reloadingLLM ? "Reloading Cleanup Model…" : "Reload Cleanup Model") {
                            controller.reloadCleanupModel()
                        }
                        .disabled(controller.reloadingLLM || !controller.processingJobs.isEmpty ||
                                  !controller.downloadingModelIDs.isEmpty)
                    }
                    if !controller.usesCustomServer {
                        Divider()
                        Button("Restart Engine") { controller.restartManagedServer() }
                    }
                } label: {
                    Label("Engine Actions", systemImage: "ellipsis.circle")
                }
                .help("More engine actions")
            }
        }
        .task {
            while !Task.isCancelled {
                if NSApp.windows.contains(where: { $0.isVisible && $0.occlusionState.contains(.visible) }) {
                    await controller.fetchServerModels()
                }
                // Fast updates only while something is changing.
                let busy = controller.modelsPreparing || !controller.downloadingModelIDs.isEmpty
                    || ["loading", "unloading"].contains(controller.selectedLLMMemoryState)
                    || controller.serverModels.isEmpty
                do {
                    try await Task.sleep(for: .seconds(busy ? 1 : 10))
                } catch {
                    break
                }
            }
        }
        .confirmationDialog(
            "Delete \(modelPendingDeletion?.name ?? "model")?",
            isPresented: Binding(
                get: { modelPendingDeletion != nil },
                set: { if !$0 { modelPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let model = modelPendingDeletion {
                Button("Delete Model", role: .destructive) {
                    controller.deleteModel(file: model.file)
                    ToastCenter.shared.show("\(model.name) Deleted", symbol: "trash.fill")
                    modelPendingDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) { modelPendingDeletion = nil }
        } message: {
            Text(controller.usesCustomServer
                 ? "This deletes the model from the connected server. You can download it again later."
                 : "This deletes the model from this Mac. You can download it again later.")
        }
        .confirmationDialog(
            "Replace the connection token?",
            isPresented: $confirmTokenRotation,
            titleVisibility: .visible
        ) {
            Button("Replace Token", role: .destructive) {
                controller.regenerateLANToken()
                ToastCenter.shared.show("New Token Created", symbol: "key.fill")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Devices using the current token will disconnect until you enter the new one.")
        }
    }

    private func checkNow() {
        checking = true
        Task { @MainActor in
            await controller.refreshServerHealth()
            checking = false
            ToastCenter.shared.show(
                controller.serverIsReady ? "Engine Is Ready" : "Engine Needs Attention",
                symbol: controller.serverIsReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
        }
    }

    @ViewBuilder
    private var installStatus: some View {
        if !controller.usesCustomServer {
            switch controller.toolInstallState {
            case .idle, .ready:
                EmptyView()
            case .installing(let formulae):
                LabeledContent {
                    ProgressView().controlSize(.small)
                } label: {
                    RowLabel(
                        title: "Installing \(formulae.joined(separator: " and "))",
                        subtitle: "Homebrew is installing the speech tools. This may take a few minutes.",
                        symbol: "arrow.down.circle"
                    )
                }
            case .failed(let message, let homebrewMissing):
                LabeledContent {
                    HStack {
                        if homebrewMissing {
                            Link("Install Homebrew", destination: URL(string: "https://brew.sh/")!)
                        }
                        Button("Retry") { controller.retryInferenceToolInstall() }
                            .omilButton()
                    }
                } label: {
                    RowLabel(title: message, subtitle: homebrewMissing
                             ? "Install Homebrew, then run the command below in Terminal."
                             : "You can also run the command below in Terminal.",
                             symbol: "exclamationmark.triangle")
                }
                LabeledContent {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(LocalServerManager.manualInstallCommand, forType: .string)
                    }
                    .omilButton()
                } label: {
                    Text(LocalServerManager.manualInstallCommand)
                        .font(OmilFont.mono)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// One stage of the pipeline: which model it uses and whether that model is ready.
private struct ModelChoiceRow: View {
    let stage: String
    let detail: String
    let symbol: String
    @Binding var selection: String
    let activeFile: String
    let options: [ModelOption]
    @ObservedObject var controller: DictationController

    private var info: DictationController.ServerModelInfo? { controller.modelInfo(file: selection) }
    private var downloaded: Bool? { controller.modelIsDownloaded(file: selection) }
    private var downloading: Bool { controller.modelIsDownloading(file: selection) }

    var body: some View {
        LabeledContent {
            HStack(spacing: 12) {
                status
                Picker(stage, selection: $selection) {
                    ForEach(options, id: \.file) { option in
                        Text("\(option.name) — \(option.size)").tag(option.file)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(controller.modelsPreparing)
            }
        } label: {
            RowLabel(
                title: stage,
                subtitle: selection != activeFile
                    ? "Current: \(options.first(where: { $0.file == activeFile })?.name ?? activeFile)"
                    : detail,
                symbol: symbol
            )
        }
    }

    @ViewBuilder
    private var status: some View {
        let fileState = info?.fileState
        HStack(spacing: 6) {
            if fileState == "downloading" || downloading {
                ProgressView().controlSize(.small)
                Text(percent.map { "\($0)%" } ?? "Downloading")
            } else if fileState == "verifying" || fileState == "checking" {
                ProgressView().controlSize(.small)
                Text(fileState == "verifying" ? "Verifying" : "Checking")
            } else if downloaded == true {
                memoryStatus
            } else if fileState == "failed" {
                Button("Repair") { controller.downloadModel(file: selection) }
                    .omilButton(prominent: true)
                    .disabled(controller.modelsPreparing)
            } else if downloaded == false {
                Button("Download") { controller.downloadModel(file: selection) }
                    .omilButton(prominent: true)
                    .disabled(controller.modelsPreparing)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .font(OmilFont.callout)
        .foregroundStyle(.secondary)
    }

    private var percent: Int? {
        guard let received = info?.receivedBytes, let total = info?.totalBytes, total > 0 else { return nil }
        return min(100, max(0, Int(Double(received) / Double(total) * 100)))
    }

    @ViewBuilder
    private var memoryStatus: some View {
        switch info?.memoryState {
        case "loading":
            ProgressView().controlSize(.small)
            Text("Loading")
        case "ready":
            Text("Loaded")
        case "inUse":
            Text("In use")
        case "unloading":
            ProgressView().controlSize(.small)
            Text("Releasing")
        case "failed":
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(OmilTheme.warning)
            Text("Load failed")
        default:
            Text("On demand")
        }
    }
}

private struct ModelLibrarySections: View {
    @ObservedObject var controller: DictationController
    let showsAll: Bool
    let requestDelete: (ModelOption) -> Void

    private var actionsLocked: Bool {
        controller.phase == .recording || controller.phase == .preparing ||
        !controller.processingJobs.isEmpty || controller.modelsPreparing
    }

    var body: some View {
        Group {
            section(title: "Transcription Models", options: whisperModelOptions,
                    activeFile: controller.whisperFile, isWhisper: true)
            section(title: "Cleanup Models", options: rewriteModelOptions,
                    activeFile: controller.llmFile, isWhisper: false)
        }
    }

    private func section(title: String, options: [ModelOption], activeFile: String, isWhisper: Bool) -> some View {
        let installed = options.filter { controller.modelIsDownloaded(file: $0.file) == true }
        let visible = showsAll ? options : options.filter {
            let state = controller.modelInfo(file: $0.file)?.fileState
            return controller.modelIsDownloaded(file: $0.file) == true || controller.modelIsDownloading(file: $0.file)
                || state == "failed" || state == "downloading" || state == "verifying"
        }
        return Section {
            if controller.serverModels.isEmpty {
                LabeledContent("Checking available models") { ProgressView().controlSize(.small) }
            } else if visible.isEmpty {
                Text("None installed. Choose All Models in the toolbar to download one.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visible, id: \.file) { option in
                    row(option, activeFile: activeFile, isWhisper: isWhisper)
                }
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                Text("\(installed.count) installed")
                    .fontWeight(.regular)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ option: ModelOption, activeFile: String, isWhisper: Bool) -> some View {
        let info = controller.modelInfo(file: option.file)
        let isActive = option.file == activeFile
        let isDownloading = controller.modelIsDownloading(file: option.file) ||
            info?.fileState == "downloading" || info?.fileState == "verifying"
        let needsRepair = info?.fileState == "failed" && info?.downloaded != true
        let inUse = isActive && info?.downloaded == true
        return LabeledContent {
            HStack(spacing: 12) {
                Text(option.size)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if isDownloading {
                    ProgressView().controlSize(.small)
                } else if inUse {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(OmilTheme.mint)
                        .help("In use")
                } else if info?.downloaded == true {
                    Button("Use") {
                        if isWhisper { controller.chooseWhisperModel(file: option.file) }
                        else { controller.chooseLLMModel(file: option.file) }
                        ToastCenter.shared.show("Switching to \(option.name)", symbol: "arrow.triangle.2.circlepath.circle.fill")
                    }
                    .omilButton()
                    .disabled(actionsLocked)
                } else {
                    Button(needsRepair ? "Repair" : "Download") {
                        controller.downloadModel(file: option.file)
                        ToastCenter.shared.show("Downloading \(option.name)", symbol: "arrow.down.circle.fill")
                    }
                        .omilButton()
                        .disabled(actionsLocked || info == nil)
                }
                if info?.downloaded == true && !isActive {
                    RowAction(symbol: "trash", label: "Delete \(option.name)", role: .destructive) { requestDelete(option) }
                        .disabled(actionsLocked)
                }
            }
        } label: {
            Text(option.name)
            Text(status(for: info, isActive: isActive, isDownloading: isDownloading))
                .foregroundStyle(needsRepair ? OmilTheme.warning : .secondary)
        }
    }

    private func status(for info: DictationController.ServerModelInfo?, isActive: Bool, isDownloading: Bool) -> String {
        guard let info else { return "Checking availability" }
        if isDownloading {
            if let received = info.receivedBytes, let total = info.totalBytes, total > 0 {
                return "Downloading · \(min(100, Int(Double(received) / Double(total) * 100)))%"
            }
            return "Downloading"
        }
        if info.fileState == "failed" { return info.fileError ?? "Needs repair" }
        if info.downloaded { return isActive ? "In use" : "Installed" }
        return "Available to download"
    }
}

private struct LANSharingSection: View {
    @ObservedObject var controller: DictationController
    @Binding var confirmTokenRotation: Bool
    @State private var revealToken = false
    @State private var showPairingCode = false

    private var connectionLocked: Bool {
        controller.phase == .recording || controller.phase == .preparing || controller.phase == .processing
    }

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { controller.lanSharingEnabled },
                set: { controller.setLANSharing($0) }
            )) {
                RowLabel(
                    title: "Share with iPhone and iPad",
                    subtitle: controller.usesCustomServer
                        ? "Switch to this Mac's engine to share it."
                        : controller.lanSharingEnabled
                            ? "Your devices on this network can use this Mac's engine."
                            : "Only this Mac uses your speech models.",
                    symbol: "iphone.and.arrow.forward"
                )
            }
            .toggleStyle(.switch)
            .disabled(controller.usesCustomServer || connectionLocked)

            if controller.lanSharingEnabled && !controller.usesCustomServer {
                if let credentials = controller.lanCredentials {
                    LabeledContent("Address") {
                        Text(verbatim: credentials.endpoint)
                            .font(OmilFont.mono)
                            .textSelection(.enabled)
                    }
                    LabeledContent("Token") {
                        HStack(spacing: 10) {
                            Text(revealToken ? credentials.token : String(repeating: "•", count: 16))
                                .font(OmilFont.mono)
                                .textSelection(.enabled)
                                .lineLimit(1)
                            RowAction(symbol: revealToken ? "eye.slash" : "eye", label: revealToken ? "Hide Token" : "Show Token") {
                                revealToken.toggle()
                            }
                        }
                    }
                    HStack {
                        Button("New Token…") { confirmTokenRotation = true }
                            .omilButton()
                            .disabled(connectionLocked)
                        Spacer()
                        Button("Copy Setup") {
                            controller.copyLANCredentials()
                            ToastCenter.shared.show("Connection Details Copied", symbol: "doc.on.doc.fill")
                        }
                            .omilButton()
                        Button("Pair iPhone…") { showPairingCode = true }
                            .omilButton(prominent: true)
                    }
                } else {
                    LabeledContent("Restarting the engine for network access") {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        } header: {
            Text("Your Devices")
        } footer: {
            if controller.lanSharingEnabled {
                Text("Only share the token with devices you trust.")
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showPairingCode) {
            if let credentials = controller.lanCredentials {
                LANPairingSheet(credentials: credentials)
            }
        }
    }
}

private struct LANPairingSheet: View {
    @Environment(\.dismiss) private var dismiss
    let credentials: LANConnectionCredentials

    private let code: NSImage?

    init(credentials: LANConnectionCredentials) {
        self.credentials = credentials
        code = Self.qrCode(for: credentials)
    }

    private static func qrCode(for credentials: LANConnectionCredentials) -> NSImage? {
        guard let url = ServerConfig(host: credentials.host, port: credentials.port, token: credentials.token).pairingURL,
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let code {
                    Image(nsImage: code)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 200, height: 200)
                        .padding(14)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityLabel("Omil server pairing QR code")
                }
                VStack(alignment: .leading, spacing: 10) {
                    PairingStep(number: 1, text: "Open Omil on your iPhone.")
                    PairingStep(number: 2, text: "Go to Settings → Your Mac and tap Scan QR Code.")
                    PairingStep(number: 3, text: "Point the camera at this code.")
                }
                .frame(maxWidth: 280, alignment: .leading)
                Label("This code includes your connection token. Only show it to devices you trust.", systemImage: "lock.fill")
                    .font(OmilFont.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                Text(verbatim: credentials.endpoint)
                    .font(OmilFont.mono)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            .padding(28)
            .navigationTitle("Pair iPhone")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(width: 400)
        .omilAppearance()
    }
}

private struct PairingStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(OmilTheme.signalInk)
                .frame(width: 20, height: 20)
                .background(OmilTheme.signal, in: Circle())
            Text(text)
                .font(OmilFont.body)
                .foregroundStyle(OmilTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct EmptyState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
                .symbolRenderingMode(.hierarchical)
        } description: {
            Text(detail)
        }
        .foregroundStyle(OmilTheme.muted)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StatusLabel: View {
    let phase: DictationController.Phase
    let environmentReady: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(OmilFont.caption.weight(.medium))
                .foregroundStyle(OmilTheme.muted)
        }
        .padding(.horizontal, 11)
        .frame(height: 24)
        .liquidGlass(in: Capsule())
        .animation(OmilMotion.quick, value: label)
    }

    private var label: String {
        switch phase {
        case .idle: return environmentReady ? "Ready" : "Setup needed"
        case .preparing: return "Preparing"
        case .recording: return "Recording"
        case .processing: return "Processing"
        case .ready: return "Finished"
        case .failed: return "Could not finish"
        }
    }

    private var color: Color {
        switch phase {
        case .recording: return OmilTheme.coral
        case .failed: return OmilTheme.warning
        case .preparing, .processing: return OmilTheme.signal
        case .idle: return environmentReady ? OmilTheme.mint : OmilTheme.warning
        case .ready: return OmilTheme.mint
        }
    }
}

private struct ModePicker: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        Picker("Cleanup", selection: $controller.cleanupMode) {
            Text("Clean").tag(CleanupMode.clean)
            Text("Verbatim").tag(CleanupMode.verbatim)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Clean removes filler words. Verbatim keeps every spoken word.")
    }
}

/// A glass segmented control with a sliding thumb.
struct SegmentedTabs<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let selected = selection == option
                Button {
                    withAnimation(OmilMotion.standard) { selection = option }
                } label: {
                    Text(label(option))
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? OmilTheme.ink : OmilTheme.muted)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(OmilTheme.ink.opacity(GlassLook.isDark ? 0.14 : 0.09))
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .liquidGlass(in: Capsule())
    }
}

private struct ProcessingTrack: View {
    let stage: DictationController.ProcessingStage

    var body: some View {
        HStack(spacing: 10) {
            ForEach(DictationController.ProcessingStage.allCases.filter { $0 != .queued }, id: \.rawValue) { item in
                if item != .transcribing {
                    Capsule()
                        .fill(item.rawValue <= stage.rawValue ? OmilTheme.signal : OmilTheme.lineStrong)
                        .frame(width: 18, height: 2)
                }
                HStack(spacing: 5) {
                    Image(systemName: item.rawValue < stage.rawValue ? "checkmark.circle.fill" : item.icon)
                        .font(OmilFont.caption.weight(.semibold))
                        .foregroundStyle(item.rawValue <= stage.rawValue ? OmilTheme.signal : OmilTheme.faint)
                    Text(item.title)
                        .font(.system(size: 12, weight: item == stage ? .semibold : .regular))
                        .foregroundStyle(item == stage ? OmilTheme.ink : OmilTheme.muted)
                }
                .opacity(item.rawValue <= stage.rawValue ? 1 : 0.6)
            }
        }
        .animation(OmilMotion.standard, value: stage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Processing: \(stage.title)")
    }
}

struct LiveSignalRail: View {
    @ObservedObject var meter: AudioMeter

    var body: some View {
        SignalRail(levels: meter.levels)
    }
}

struct SignalRail: View {
    let levels: [Double]

    var body: some View {
        let ink = OmilTheme.ink
        return Canvas { context, size in
            let visible = levels.suffix(36)
            guard !visible.isEmpty else { return }
            let spacing: CGFloat = 3
            let width = max(1, (size.width - CGFloat(visible.count - 1) * spacing) / CGFloat(visible.count))
            for (index, level) in visible.enumerated() {
                let height = barHeight(level: level, available: size.height)
                let rect = CGRect(x: CGFloat(index) * (width + spacing),
                                  y: (size.height - height) / 2,
                                  width: width, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: min(width, height) / 2),
                             with: .color(ink.opacity(0.35 + min(1, max(0, level)) * 0.6)))
            }
        }
        .accessibilityHidden(true)
    }

    private func barHeight(level: Double, available: CGFloat) -> CGFloat {
        let value = min(1, max(0, level))
        return max(3, 3 + available * 0.9 * value)
    }

}

private struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(OmilFont.caption.weight(.medium))
            .foregroundStyle(OmilTheme.ink)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .frame(minWidth: 22)
            .frame(height: 22)
            .background(OmilTheme.panelLifted, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(OmilTheme.lineStrong, lineWidth: 1)
            }
    }
}

/// Observes the controller directly so the notice appears and disappears live.
private struct SidebarEngineNotice: View {
    @ObservedObject var controller: DictationController
    let action: () -> Void

    var body: some View {
        Group {
            if !controller.serverIsReady {
                EngineStatusRow(controller: controller, action: action)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(OmilMotion.standard, value: controller.serverIsReady)
    }
}

/// Sidebar engine notice. Silent when healthy; a quiet "Starting" while models
/// warm up; a warning only when something actually needs the user.
private struct EngineStatusRow: View {
    @ObservedObject var controller: DictationController
    let action: () -> Void

    private var starting: Bool {
        controller.modelsPreparing
            || !controller.downloadingModelIDs.isEmpty
            || controller.serverHealth.localizedCaseInsensitiveContains("starting")
            || controller.serverHealth.localizedCaseInsensitiveContains("restarting")
            || controller.serverHealth.isEmpty
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if starting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(OmilTheme.warning)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(starting ? "Starting Engine…" : "Engine Not Ready")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OmilTheme.ink)
                    Text(starting ? "Speech models are loading" : "Open Engine to fix")
                        .font(OmilFont.caption)
                        .foregroundStyle(OmilTheme.muted)
                }
                Spacer(minLength: 0)
                if !starting {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(OmilTheme.muted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background((starting ? OmilTheme.ink.opacity(0.05) : OmilTheme.warning.opacity(0.1)),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Engine")
    }
}

struct OmilMark: View {
    let size: CGFloat
    var body: some View {
        Image("BrandIcon")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct IconAction: View {
    let icon: String
    let label: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
        }
        .buttonStyle(IconButtonStyle())
        .disabled(disabled)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Native menu picker; the system control reads as more trustworthy than a custom popover.
struct OmilPickerField<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options, id: \.self) { option in
                Text(label(option)).tag(option)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityLabel(title)
    }
}

struct HoverButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = OmilRadius.control

    func makeBody(configuration: Configuration) -> some View {
        HoverButtonBody(configuration: configuration, cornerRadius: cornerRadius)
    }
}

private struct HoverButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let cornerRadius: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        configuration.label
            .background(
                isEnabled && (hovered || configuration.isPressed) ? OmilTheme.panelLifted.opacity(0.8) : .clear,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .onHover { hovered = $0 }
            .animation(OmilMotion.quick, value: hovered)
    }
}

/// Mac-side access to the active palette. Views read these statics; the
/// window tree is rebuilt when the preset or color scheme changes.
@MainActor
enum OmilTheme {
    private static var palette: ThemePalette { AppAppearance.shared.palette }

    private static var dark: Bool { AppAppearance.shared.colorScheme == .dark }

    // Translucent surfaces so they read over the blurred window backdrop.
    static var panel: Color { Color(hex: palette.panel).opacity(dark ? 0.5 : 0.62) }
    static var panelDeep: Color { ink.opacity(dark ? 0.05 : 0.035) }
    static var panelLifted: Color { ink.opacity(dark ? 0.09 : 0.06) }
    static var line: Color { ink.opacity(dark ? 0.09 : 0.08) }
    static var lineStrong: Color { ink.opacity(dark ? 0.16 : 0.14) }
    static var ink: Color { Color(hex: palette.ink) }
    static var muted: Color { Color(hex: palette.muted) }
    static var faint: Color { Color(hex: palette.faint) }
    static var signal: Color { Color(hex: palette.signal) }
    static var signalInk: Color { Color(hex: palette.signalInk) }
    /// Fill for grouped content, matching Form's grouped sections.
    static var groupFill: Color { ink.opacity(dark ? 0.07 : 0.045) }
    static var coral: Color { Color(hex: palette.recording) }
    static var mint: Color { Color(hex: palette.success) }
    static var warning: Color { Color(hex: palette.warning) }
}

extension NSColor {
    convenience init(hex: UInt) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
