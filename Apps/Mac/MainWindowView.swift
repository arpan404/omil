import AppKit
import Combine
import CoreImage
import SwiftUI
import OmilCore

// MARK: - Product shell

@MainActor
final class AppAppearance: ObservableObject {
    static let shared = AppAppearance()
    @Published private(set) var colorScheme: ColorScheme
    @Published var themePreset: ThemePreset = .fog
    private var observation: NSKeyValueObservation?

    private init() {
        colorScheme = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
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
        let palette = appearance.themePreset.palette(for: appearance.colorScheme)
        content.environment(\.colorScheme, appearance.colorScheme)
            .tint(Color(hex: palette.signal))
            .background(Color(hex: palette.canvas).ignoresSafeArea())
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

    @ViewBuilder
    func omilFullScreenToolbar() -> some View {
        if #available(macOS 15.0, *) {
            windowToolbarFullScreenVisibility(.onHover)
        } else {
            self
        }
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
                        if name == NSWindow.willEnterFullScreenNotification {
                            self.window?.toolbar?.isVisible = false
                        } else if name == NSWindow.willExitFullScreenNotification {
                            self.window?.toolbar?.isVisible = true
                        } else {
                            self.updateWindow()
                        }
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
        if !window.backgroundColor.isEqual(chromeColor) {
            window.backgroundColor = chromeColor
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

private struct FullScreenReader: NSViewRepresentable {
    @Binding var isFullScreen: Bool

    func makeNSView(context: Context) -> FullScreenReaderView {
        let view = FullScreenReaderView()
        view.onChange = { isFullScreen = $0 }
        return view
    }

    func updateNSView(_ view: FullScreenReaderView, context: Context) {
        view.onChange = { isFullScreen = $0 }
    }
}

private final class FullScreenReaderView: NSView {
    var onChange: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var lastReported: Bool?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        lastReported = nil
        guard let window else { return }
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reportState(name == NSWindow.willEnterFullScreenNotification ||
                                      name == NSWindow.didEnterFullScreenNotification)
                }
            })
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            self.reportState(window.styleMask.contains(.fullScreen))
        }
    }

    deinit {
        MainActor.assumeIsolated {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func reportState(_ isFullScreen: Bool) {
        guard lastReported != isFullScreen else { return }
        lastReported = isFullScreen
        onChange?(isFullScreen)
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
        case .history: return "clock.arrow.circlepath"
        case .snippets: return "text.badge.plus"
        case .dictionary: return "text.book.closed"
        case .styles: return "slider.horizontal.3"
        case .engine: return "cpu"
        }
    }
}

struct RootView: View {
    let controller: DictationController
    @ObservedObject private var settings = AppContext.settingsCoordinator
    @State private var onboarded: Bool

    init(controller: DictationController) {
        self.controller = controller
        _onboarded = State(initialValue: controller.onboarded)
    }

    var body: some View {
        Group {
            if onboarded {
                MainWindowView(controller: controller)
            } else {
                OnboardingView(controller: controller)
            }
        }
        .frame(minWidth: 760, minHeight: 540)
        .omilAppearance(fullSizeTitlebar: true, hidesFullScreenToolbar: true)
        .sheet(isPresented: $settings.isPresented) {
            SettingsView(controller: controller)
        }
        .onReceive(controller.$onboarded.removeDuplicates()) { onboarded = $0 }
    }
}

struct MainWindowView: View {
    let controller: DictationController
    @ObservedObject private var appearance = AppAppearance.shared
    @State private var section: MainSection? = .record
    @State private var isFullScreen = false
    @State private var fullScreenSidebarVisible = true
    var body: some View {
        let toolbarCanvas = Color(hex: appearance.themePreset.palette(for: appearance.colorScheme).canvas)
        Group {
            if isFullScreen {
                HStack(spacing: 0) {
                    if fullScreenSidebarVisible {
                        sidebar
                            .frame(width: 228)
                            .overlay(alignment: .trailing) { OmilTheme.line.frame(width: 1) }
                    }
                    detail
                }
                .overlay(alignment: .topLeading) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            fullScreenSidebarVisible.toggle()
                        }
                    } label: {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(OmilTheme.muted)
                    .background(OmilTheme.panelLifted, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.leading, fullScreenSidebarVisible ? 182 : 12)
                    .padding(.top, 12)
                    .help(fullScreenSidebarVisible ? "Hide Sidebar" : "Show Sidebar")
                }
            } else {
                NavigationSplitView {
                    sidebar
                } detail: {
                    detail
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .background(toolbarCanvas.ignoresSafeArea())
        .toolbarBackground(toolbarCanvas, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .tint(OmilTheme.signal)
        .id("\(appearance.themePreset.id)-\(appearance.colorScheme)")
        .background(FullScreenReader(isFullScreen: $isFullScreen))
    }

    private var detail: some View {
        ZStack {
            OmilTheme.canvas.ignoresSafeArea()
            Group {
                switch section ?? .record {
                case .record: RecorderView(controller: controller)
                case .history: HistoryView(controller: controller)
                case .snippets: SnippetsView(controller: controller)
                case .dictionary: DictionaryView(controller: controller)
                case .styles: StylesView(controller: controller)
                case .engine: EngineView(controller: controller)
                }
            }
            .frame(maxWidth: 1280)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                OmilMark(size: 36)
                Text("Omil")
                    .font(OmilType.display(18))
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 24)

            ScrollView {
                VStack(spacing: 3) {
                    ForEach(MainSection.allCases, id: \.self) { item in
                        Button {
                            section = item
                        } label: {
                            Label(item.title, systemImage: item.icon)
                                .font(.system(size: 13, weight: section == item ? .semibold : .medium))
                                .symbolVariant(section == item ? .fill : .none)
                                .foregroundStyle(section == item ? OmilTheme.ink : OmilTheme.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 11)
                                .frame(height: 38)
                                .background(section == item ? OmilTheme.panelLifted : .clear, in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(HoverButtonStyle(cornerRadius: 9))
                    }
                }
                .padding(.horizontal, 10)
            }

            VStack(spacing: 12) {
                Divider().overlay(OmilTheme.line)
                EngineStatusRow(controller: controller)
                Button {
                    AppContext.appDelegate?.showSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(SidebarButtonStyle())
            }
            .padding(16)
        }
        .background(OmilTheme.sidebar)
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 245)
    }
}

// MARK: - Recorder

struct RecorderView: View {
    @ObservedObject var controller: DictationController
    var showsHeader = true
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
                VStack(alignment: .leading, spacing: 22) {
                    if showsHeader { RecorderHeader(controller: controller) }

                    if controller.micPermission != .granted {
                        PermissionStrip(controller: controller)
                    }

                    if !hasContent { Spacer(minLength: 24) }
                    recorderColumn
                    if !hasContent { Spacer(minLength: 24) }
                }
                .frame(minHeight: max(0, geometry.size.height - (showsHeader ? 60 : 0)))
                .padding(showsHeader ? 30 : 0)
            }
        }
        .onChange(of: controller.phase) { _, phase in
            if phase == .recording, startedAt == nil { startedAt = Date() }
            if phase != .recording { startedAt = nil }
            if phase == .ready { resultTab = .clean }
        }
    }

    private var hasResult: Bool {
        !controller.lastCleaned.isEmpty || !controller.lastRaw.isEmpty || !controller.lastDiff.isEmpty
    }

    private var hasContent: Bool {
        hasResult || !controller.processingJobs.isEmpty || !controller.history.isEmpty
    }

    private var recorderColumn: some View {
        VStack(spacing: 18) {
            RecorderStage(controller: controller, startedAt: startedAt)
            if !controller.processingJobs.isEmpty { PendingTranscriptionsCard(jobs: controller.processingJobs) }
            if hasResult {
                ResultCard(controller: controller, selectedTab: $resultTab)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if controller.historyEnabled && !controller.history.isEmpty {
                RecentTranscriptionsCard(entries: Array(controller.history.prefix(12)))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PendingTranscriptionsCard: View {
    let jobs: [DictationController.ProcessingJob]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(jobs.count == 1 ? "IN PROGRESS" : "\(jobs.count) IN PROGRESS")
                    .font(OmilType.utility(10, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(OmilTheme.muted)
                Spacer()
                Text("You can record again")
                    .font(OmilType.utility(10))
                    .foregroundStyle(OmilTheme.faint)
            }
            ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    if jobs.count > 1 {
                        Text("\(index + 1)")
                            .font(OmilType.utility(11, weight: .bold))
                            .foregroundStyle(OmilTheme.signal)
                            .frame(width: 20, alignment: .leading)
                    }
                    Image(systemName: job.stage.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(OmilTheme.muted)
                    Text(job.stage.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OmilTheme.ink)
                    Spacer()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(jobs.count == 1 ? job.stage.title : "Recording \(index + 1), \(job.stage.title)")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OmilTheme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(OmilTheme.line))
    }
}

private struct RecentTranscriptionsCard: View {
    let entries: [DictationController.HistoryEntry]
    @State private var expandedIDs: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("RECENT TRANSCRIPTIONS")
                    .font(OmilType.utility(10, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(OmilTheme.muted)
                Spacer()
                Text("Latest \(entries.count)")
                    .font(OmilType.utility(10))
                    .foregroundStyle(OmilTheme.faint)
            }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        if !expandedIDs.insert(entry.id).inserted { expandedIDs.remove(entry.id) }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: expandedIDs.contains(entry.id) ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 12)
                            Text(entry.cleaned)
                                .lineLimit(expandedIDs.contains(entry.id) ? nil : 2)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(entry.date.formatted(date: .omitted, time: .shortened))
                                .font(OmilType.utility(10))
                                .foregroundStyle(OmilTheme.faint)
                                .fixedSize()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(OmilTheme.ink)
                    if expandedIDs.contains(entry.id) {
                        Button("Copy transcript") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.cleaned, forType: .string)
                        }
                        .buttonStyle(.plain)
                        .font(OmilType.utility(10, weight: .medium))
                        .foregroundStyle(OmilTheme.signal)
                        .padding(.leading, 22)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(OmilTheme.panel, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(OmilTheme.line))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RecorderHeader: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Dictate")
                .font(OmilType.display(30))
                .foregroundStyle(OmilTheme.ink)
            Spacer()
        }
    }
}

private struct PermissionStrip: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(OmilTheme.warning)
                .frame(width: 32, height: 32)
                .background(OmilTheme.warning.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.micPermission == .denied ? "Microphone access is off" : "Allow microphone access")
                    .font(.system(size: 13, weight: .semibold))
                Text(controller.micPermission == .denied ? "Open System Settings to enable recording." : "Omil needs it to record your voice.")
                    .font(.system(size: 12))
                    .foregroundStyle(OmilTheme.muted)
            }
            Spacer()
            Button(controller.micPermission == .denied ? "Open Settings" : "Allow") { controller.requestMic() }
                .buttonStyle(QuietButtonStyle())
        }
        .padding(14)
        .background(OmilTheme.warning.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(OmilTheme.warning.opacity(0.22)))
    }
}

private struct RecorderStage: View {
    @ObservedObject var controller: DictationController
    let startedAt: Date?

    var active: Bool { controller.phase == .recording }
    var busy: Bool { controller.phase == .preparing || controller.phase == .processing }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                StatusLabel(
                    phase: controller.phase,
                    environmentReady: controller.micPermission == .granted && controller.serverIsReady
                )
                if active || controller.phase == .preparing {
                    Button("Cancel") { controller.cancel() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(OmilTheme.muted)
                }
                Spacer()
                ModePicker(controller: controller)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)

            Spacer(minLength: 34)

            Group {
                if active {
                    LiveSignalRail(meter: controller.audioMeter)
                } else if controller.phase == .processing {
                    ProcessingTrack(stage: controller.processingStage)
                } else {
                    EmptyView()
                }
            }
            .frame(height: active || controller.phase == .processing ? 52 : 0)
            .padding(.horizontal, 56)

            if controller.phase == .preparing || controller.phase == .processing {
                ZStack {
                    Circle()
                        .fill(OmilTheme.signal.opacity(0.1))
                        .frame(width: 76, height: 76)
                    Circle()
                        .fill(OmilTheme.panelLifted)
                        .frame(width: 56, height: 56)
                    ProgressView()
                        .controlSize(.small)
                        .tint(OmilTheme.signal)
                }
            } else {
                Button(action: toggle) {
                    ZStack {
                        Circle()
                            .fill((active ? OmilTheme.coral : OmilTheme.signal).opacity(0.07))
                            .frame(width: 128, height: 128)
                        Circle()
                            .stroke(active ? OmilTheme.coral.opacity(0.3) : OmilTheme.signal.opacity(0.3), lineWidth: 1)
                            .frame(width: 88, height: 88)
                        Circle()
                            .fill(active ? OmilTheme.coral : OmilTheme.signal)
                            .frame(width: 68, height: 68)
                            .shadow(color: (active ? OmilTheme.coral : OmilTheme.signal).opacity(0.2), radius: 22, y: 8)
                        Image(systemName: active ? "stop.fill" : "mic.fill")
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(active ? Color.white : OmilTheme.signalInk)
                    }
                }
                .buttonStyle(.plain)
                .disabled(busy || !controller.serverIsReady)
                .accessibilityLabel(active ? "Stop recording" : "Start recording")
            }

            VStack(spacing: 8) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(primaryStatus)
                        .font(OmilType.display(23))
                        .foregroundStyle(OmilTheme.ink)
                        .contentTransition(.numericText())
                }
                if !secondaryStatus.isEmpty {
                    Text(secondaryStatus)
                        .font(.system(size: 13))
                        .foregroundStyle(OmilTheme.muted)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(maxWidth: 470)
                }
            }
            .padding(.top, 12)

            Spacer(minLength: 34)

            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    KeyCap(text: shortcutKey)
                    Text("hold to speak")
                }
                Rectangle()
                    .fill(OmilTheme.lineStrong)
                    .frame(width: 1, height: 18)
                HStack(spacing: 8) {
                    KeyCap(text: "⌃⌥O")
                    Text("start / stop")
                }
                Text("Esc to cancel")
                    .foregroundStyle(OmilTheme.faint)
            }
            .font(OmilType.utility(10, weight: .medium))
            .tracking(0.2)
            .foregroundStyle(OmilTheme.muted)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(OmilTheme.panelDeep.opacity(0.66))
        }
        .frame(height: 390)
        .background {
            RoundedRectangle(cornerRadius: 20)
                .fill(OmilTheme.panel)
                .overlay {
                    RadialGradient(colors: [OmilTheme.signal.opacity(0.09), .clear], center: .center, startRadius: 12, endRadius: 330)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                }
        }
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(OmilTheme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var shortcutKey: String {
        HotkeyManager.shared.pushToTalkName
            .replacingOccurrences(of: "Right ", with: "R ")
            .uppercased()
    }

    private var primaryStatus: String {
        switch controller.phase {
        case .idle:
            if controller.micPermission != .granted { return "Allow microphone" }
            if !controller.serverIsReady { return "Set up transcription" }
            return "Ready"
        case .preparing: return "Getting ready"
        case .recording:
            guard let startedAt else { return "Listening" }
            let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        case .processing: return controller.processingStage.title
        case .ready:
            if controller.processingJobs.count == 1 { return controller.processingJobs[0].stage.title }
            if controller.processingJobs.count > 1 { return "\(controller.processingJobs.count) processing" }
            return controller.lastCleaned.isEmpty ? "Nothing heard" : "Ready"
        case .failed: return "Needs attention"
        }
    }

    private var secondaryStatus: String {
        switch controller.phase {
        case .idle: return controller.micPermission != .granted ? "Allow microphone access to start transcribing." : controller.serverIsReady ? "Click the microphone to dictate into your last text field, or use the shortcut without switching apps." : "Open Engine to check your speech models."
        case .recording: return controller.draftText.isEmpty ? "Listening for your voice" : controller.draftText
        case .ready where !controller.processingJobs.isEmpty:
            return "Ready for another recording while these finish."
        default: return controller.statusMessage
        }
    }

    private func toggle() {
        active ? controller.stop() : controller.start()
    }
}

private struct ResultCard: View {
    @ObservedObject var controller: DictationController
    @Binding var selectedTab: RecorderView.ResultTab

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 4) {
                    ForEach(RecorderView.ResultTab.allCases, id: \.self) { tab in
                        Button(tab.rawValue) { selectedTab = tab }
                            .buttonStyle(SegmentButtonStyle(selected: selectedTab == tab))
                            .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                    }
                }
                Spacer()
                if !controller.lastCleaned.isEmpty {
                    HStack(spacing: 5) {
                        IconAction(icon: "doc.on.doc", label: "Copy") { controller.copyLast() }
                        IconAction(icon: "arrow.uturn.backward", label: "Undo", disabled: !controller.canUndo) { controller.undoLast() }
                    }
                }
            }
            .padding(14)

            Divider().overlay(OmilTheme.line)

            ScrollView {
                Text(resultText)
                    .font(selectedTab == .changes ? OmilType.utility(13) : .system(size: 15))
                    .foregroundStyle(isEmpty ? OmilTheme.faint : OmilTheme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(18)
            }
            .frame(minHeight: 132, maxHeight: 190)

            if !controller.lastDeliveryMethod.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: deliverySucceeded ? "checkmark.circle.fill" : "info.circle.fill")
                        .foregroundStyle(deliverySucceeded ? OmilTheme.mint : OmilTheme.warning)
                    Text(controller.lastDeliveryMethod)
                    Spacer()
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(OmilTheme.muted)
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }
        }
        .background(OmilTheme.panel, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(OmilTheme.line))
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

// MARK: - History

enum HistoryListRow: Identifiable {
    case savedHeader
    case recording(RecoveryRecording)
    case dayHeader(Date)
    case transcript(DictationController.HistoryEntry)

    var id: String {
        switch self {
        case .savedHeader: return "saved-header"
        case .recording(let recording): return "recording-\(recording.id)"
        case .dayHeader(let day): return "day-\(day.timeIntervalSinceReferenceDate)"
        case .transcript(let entry): return "transcript-\(entry.id)"
        }
    }

    static func make(
        recordings: [RecoveryRecording],
        history: [DictationController.HistoryEntry],
        search: String
    ) -> [HistoryListRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches: (String) -> Bool = { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
        var rows: [HistoryListRow] = []
        let matchingRecordings = recordings.filter {
            matches($0.transcript ?? "") || matches($0.rawTranscript ?? "")
        }
        if !matchingRecordings.isEmpty {
            rows.append(.savedHeader)
            rows.append(contentsOf: matchingRecordings.map(HistoryListRow.recording))
        }
        var lastDay: Date?
        for entry in history.sorted(by: { $0.date > $1.date }) where matches(entry.cleaned) || matches(entry.raw) {
            let day = Calendar.current.startOfDay(for: entry.date)
            if lastDay != day {
                rows.append(.dayHeader(day))
                lastDay = day
            }
            rows.append(.transcript(entry))
        }
        return rows
    }
}

struct HistoryView: View {
    @ObservedObject var controller: DictationController
    @State private var search = ""
    @State private var rows: [HistoryListRow]
    @State private var confirmDelete: DictationController.HistoryEntry?
    @State private var confirmRecoveryDelete: RecoveryRecording?
    @State private var selectedTranscript: HistoryTranscript?

    init(controller: DictationController) {
        self.controller = controller
        _rows = State(initialValue: HistoryListRow.make(
            recordings: controller.recoveryRecordings,
            history: controller.history,
            search: ""
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "History",
                detail: "Listen to recordings and find your past transcripts."
            ) {
                Toggle("Keep history", isOn: Binding(
                    get: { controller.historyEnabled },
                    set: { controller.setHistoryEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(OmilTheme.faint)
                TextField("Search your dictations", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("Clear search")
                        .buttonStyle(.plain)
                        .foregroundStyle(OmilTheme.faint)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(OmilTheme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(OmilTheme.line))
            .padding(.horizontal, 30)
            .padding(.bottom, 18)

            if controller.history.isEmpty && controller.recoveryRecordings.isEmpty {
                EmptyState(
                    icon: "waveform.badge.mic",
                    title: "No history yet",
                    detail: "Your transcripts and saved recordings will appear here."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if rows.isEmpty && !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            EmptyState(icon: "magnifyingglass", title: "Nothing matched", detail: "Try a shorter word or phrase.")
                        }
                        ForEach(rows) { row in
                            historyRow(row)
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.bottom, 30)
                }
            }
        }
        .onChange(of: search) { _, _ in refreshRows() }
        .onReceive(controller.$history) { history in refreshRows(history: history) }
        .onReceive(controller.$recoveryRecordings) { recordings in refreshRows(recordings: recordings) }
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
                if let entry = confirmDelete { controller.deleteHistoryEntry(entry) }
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
                if let recording = confirmRecoveryDelete { controller.deleteRecovery(recording) }
                confirmRecoveryDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmRecoveryDelete = nil }
        } message: {
            Text("This permanently deletes the recording. Your transcript stays in History.")
        }
    }

    @ViewBuilder
    private func historyRow(_ row: HistoryListRow) -> some View {
        switch row {
        case .savedHeader:
            HStack(alignment: .firstTextBaseline) {
                Text("Saved recordings")
                    .font(OmilType.utility(10, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(OmilTheme.muted)
                Spacer()
                Text(controller.audioRetentionDays == 1 ? "Kept for 1 day" : "Kept for \(controller.audioRetentionDays) days")
                    .font(OmilType.utility(10))
                    .foregroundStyle(OmilTheme.faint)
            }
        case .recording(let recording):
            RecoveryRecordingCard(
                recording: recording,
                playback: controller.recoveryPlayback,
                isBusy: controller.phase == .recording || controller.phase == .preparing || controller.phase == .processing,
                play: { controller.playRecovery(recording) },
                seek: { controller.seekRecovery(recording, to: $0) },
                retry: { controller.retryRecovery(recording) },
                copy: { copy(recording.transcript ?? "") },
                viewTranscript: { selectedTranscript = transcript(for: recording) },
                delete: { confirmRecoveryDelete = recording }
            )
        case .dayHeader(let day):
            Text(controller.dayLabel(for: day).uppercased())
                .font(OmilType.utility(10, weight: .bold))
                .tracking(1)
                .foregroundStyle(OmilTheme.muted)
                .padding(.top, 12)
        case .transcript(let entry):
            HistoryCard(
                entry: entry,
                copy: { copy(entry.cleaned) },
                viewTranscript: { selectedTranscript = HistoryTranscript(entry: entry) },
                delete: { confirmDelete = entry }
            )
        }
    }

    private func refreshRows(
        recordings: [RecoveryRecording]? = nil,
        history: [DictationController.HistoryEntry]? = nil
    ) {
        rows = HistoryListRow.make(
            recordings: recordings ?? controller.recoveryRecordings,
            history: history ?? controller.history,
            search: search
        )
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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

    private var displayedText: String {
        switch tab {
        case 0: return transcript.raw ?? "Raw transcript unavailable for this older recording."
        case 1: return transcript.raw.map { DiffUtil.diff(raw: $0, cleaned: transcript.clean) }
            ?? "Changes unavailable for this older recording."
        default: return transcript.clean
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transcript").font(OmilType.display(22))
                    Text(transcript.title).font(OmilType.utility(10)).foregroundStyle(OmilTheme.muted)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            Picker("Transcript version", selection: $tab) {
                Text("Raw").tag(0)
                Text("Changes").tag(1)
                Text("Clean").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if tab == 1 && transcript.raw != nil {
                Text("[-removed]  [+added]")
                    .font(OmilType.utility(10))
                    .foregroundStyle(OmilTheme.muted)
            }
            ScrollView {
                Text(displayedText)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(OmilTheme.panel, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Spacer()
                Button("Copy") {
                    guard tab == 2 || transcript.raw != nil else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(displayedText, forType: .string)
                }
                .disabled(tab != 2 && transcript.raw == nil)
            }
        }
        .padding(24)
        .frame(width: 600, height: 470)
        .omilAppearance()
    }
}

private struct RecoveryRecordingCard: View {
    let recording: RecoveryRecording
    @ObservedObject var playback: RecoveryPlayback
    @State private var showsControls = false
    @State private var showsTranscript = false

    private var isSelected: Bool { playback.recordingID == recording.id }
    private var isPlaying: Bool { isSelected && playback.isPlaying }
    let isBusy: Bool
    let play: () -> Void
    let seek: (TimeInterval) -> Void
    let retry: () -> Void
    let copy: () -> Void
    let viewTranscript: () -> Void
    let delete: () -> Void

    private var stateLabel: String {
        switch recording.state {
        case .pending: return "Processing"
        case .ready: return "Ready"
        case .failed: return "Retry available"
        }
    }

    private var stateColor: Color {
        switch recording.state {
        case .pending: return OmilTheme.warning
        case .ready: return OmilTheme.mint
        case .failed: return OmilTheme.warning
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(OmilTheme.signal.opacity(0.12))
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OmilTheme.signal)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OmilTheme.ink)
                    HStack(spacing: 6) {
                        Text(durationLabel)
                        Text("·")
                        Circle().fill(stateColor).frame(width: 6, height: 6)
                        Text(stateLabel)
                    }
                    .font(OmilType.utility(10))
                    .foregroundStyle(OmilTheme.faint)
                }
                Spacer()
                Button(action: play) {
                    Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(isBusy)
                Button(action: retry) { Label("Transcribe again", systemImage: "arrow.clockwise") }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(isBusy)
                Menu {
                    if recording.transcript?.isEmpty == false {
                        Button("View transcript", systemImage: "text.alignleft", action: viewTranscript)
                        Button("Copy transcript", systemImage: "doc.on.doc", action: copy)
                    }
                    Button("Delete recording", role: .destructive, action: delete)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 26, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }

            Button {
                showsControls.toggle()
            } label: {
                Label(showsControls ? "Hide controls" : "Show controls", systemImage: showsControls ? "chevron.up" : "slider.horizontal.3")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(OmilTheme.muted)

            if showsControls {
                if isSelected, let error = playback.errorMessage {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(OmilTheme.warning)
                } else {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            Text(timeLabel(isSelected ? playback.position : 0))
                                .monospacedDigit()
                                .frame(width: 40, alignment: .leading)
                            Slider(value: Binding(
                                get: { isSelected ? playback.position : 0 },
                                set: { seek($0) }
                            ), in: 0...max(isSelected ? playback.duration : recording.duration, 0.01))
                            .accessibilityLabel("Playback position")
                            .accessibilityValue("\(timeLabel(isSelected ? playback.position : 0)) of \(timeLabel(isSelected ? playback.duration : recording.duration))")
                            Text(timeLabel(isSelected ? playback.duration : recording.duration))
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                        HStack(spacing: 14) {
                            Button { seek((isSelected ? playback.position : 0) - 10) } label: {
                                Image(systemName: "gobackward.10")
                            }
                            .help("Back 10 seconds")
                            .accessibilityLabel("Back 10 seconds")
                            Button { seek((isSelected ? playback.position : 0) + 10) } label: {
                                Image(systemName: "goforward.10")
                            }
                            .help("Forward 10 seconds")
                            .accessibilityLabel("Forward 10 seconds")
                            Button("Stop") { playback.stop() }
                                .disabled(!isSelected)
                            Spacer(minLength: 8)
                            OmilPickerField(
                                title: "Playback speed",
                                selection: $playback.rate,
                                options: [Float(0.75), 1, 1.25, 1.5, 2],
                                label: { "\($0.formatted())×" }
                            )
                            .frame(width: 80)
                            Image(systemName: playback.volume == 0 ? "speaker.slash" : "speaker.wave.2")
                                .accessibilityHidden(true)
                            Slider(value: $playback.volume, in: 0...1)
                                .frame(width: 80)
                                .accessibilityLabel("Playback volume")
                        }
                        .buttonStyle(.borderless)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(OmilTheme.muted)
                    .padding(.vertical, 6)
                }
            }

            if let transcript = recording.transcript, !transcript.isEmpty {
                Button {
                    showsTranscript.toggle()
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: showsTranscript ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text(transcript)
                            .lineLimit(showsTranscript ? nil : 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(OmilTheme.muted)
                if showsTranscript {
                    Button("Copy transcript", action: copy)
                        .buttonStyle(.plain)
                        .font(OmilType.utility(10, weight: .medium))
                        .foregroundStyle(OmilTheme.signal)
                        .padding(.leading, 18)
                }
            } else if let failure = recording.failureReason, !failure.isEmpty {
                Text(failure)
                    .font(.system(size: 11))
                    .foregroundStyle(OmilTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(OmilTheme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(OmilTheme.line))
        .onChange(of: isPlaying) { _, playing in
            if playing { showsControls = true }
        }
    }

    private var durationLabel: String { timeLabel(recording.duration) }

    private func timeLabel(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct HistoryCard: View {
    let entry: DictationController.HistoryEntry
    let copy: () -> Void
    let viewTranscript: () -> Void
    let delete: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(entry.date.formatted(date: .omitted, time: .shortened))
                    .font(OmilType.utility(10, weight: .semibold))
                    .foregroundStyle(OmilTheme.faint)
                Text("·")
                    .foregroundStyle(OmilTheme.faint)
                Text("\(entry.wordCount) words")
                    .font(OmilType.utility(10))
                    .foregroundStyle(OmilTheme.faint)
                Spacer()
                Button(action: copy) { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(QuietButtonStyle())
                Menu {
                    Button("View transcript", action: viewTranscript)
                    Divider()
                    Button("Delete", role: .destructive, action: delete)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 26, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
            Button { expanded.toggle() } label: {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 12)
                    Text(entry.cleaned)
                        .font(.system(size: 15))
                        .lineLimit(expanded ? nil : 2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(OmilTheme.ink)
            .accessibilityLabel(expanded ? "Collapse transcript" : "Expand transcript")
            if expanded {
                HStack(spacing: 12) {
                    Button("View original and changes", action: viewTranscript)
                    Button("Copy transcript", action: copy)
                }
                .buttonStyle(.plain)
                .font(OmilType.utility(10, weight: .medium))
                .foregroundStyle(OmilTheme.signal)
                .padding(.leading, 21)
            }

        }
        .padding(16)
        .background(OmilTheme.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(OmilTheme.line))
    }
}

// MARK: - Snippets

struct SnippetsView: View {
    @ObservedObject var controller: DictationController
    @State private var trigger = ""
    @State private var expansion = ""
    @State private var validationMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "Snippets",
                detail: "Say a short phrase to insert text you use often."
            ) { EmptyView() }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        LabeledField(label: "When I say", placeholder: "my intro", text: $trigger)

                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text("Write this")
                                Spacer()
                                Text("\(expansion.count) / 4,000")
                            }
                            .font(OmilType.utility(9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(OmilTheme.faint)

                            TextEditor(text: $expansion)
                                .accessibilityLabel("Snippet text")
                                .font(.system(size: 13))
                                .scrollContentBackground(.hidden)
                                .padding(9)
                                .frame(minHeight: 92)
                                .background(OmilTheme.canvas, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(OmilTheme.lineStrong))
                        }

                        HStack {
                            Text(validationMessage.isEmpty ? "Works alone or inside a sentence." : validationMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(validationMessage.isEmpty ? OmilTheme.muted : OmilTheme.warning)
                            Spacer()
                            Button("Add snippet") { addSnippet() }
                                .buttonStyle(SignalButtonStyle())
                                .disabled(trigger.trimmed.isEmpty || expansion.trimmed.isEmpty || trigger.count > 60 || expansion.count > 4_000)
                        }
                    }
                    .padding(18)
                    .background(OmilTheme.panel, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(OmilTheme.line))

                    Text("\(controller.snippets.count) saved snippets")
                        .font(OmilType.utility(10, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(OmilTheme.muted)

                    if controller.snippets.isEmpty {
                        EmptyState(
                            icon: "text.badge.plus",
                            title: "No snippets yet",
                            detail: "Save an address, sign-off, or introduction, then give it a short spoken phrase."
                        )
                        .frame(minHeight: 240)
                    } else {
                        ForEach(controller.snippets) { snippet in
                            HStack(alignment: .top, spacing: 14) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\"\(snippet.trigger)\"")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(OmilTheme.signal)
                                    Text(snippet.expansion)
                                        .font(.system(size: 12))
                                        .foregroundStyle(OmilTheme.muted)
                                        .lineLimit(4)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                Button(role: .destructive) { controller.deleteSnippet(snippet) } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(OmilTheme.faint)
                                .help("Delete snippet")
                            }
                            .padding(16)
                            .background(OmilTheme.panel, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(OmilTheme.line))
                        }
                    }
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 30)
            }
        }
    }

    private func addSnippet() {
        if let error = controller.addSnippet(trigger: trigger, expansion: expansion) {
            validationMessage = error
            return
        }
        trigger = ""
        expansion = ""
        validationMessage = ""
    }
}

// MARK: - Styles

struct StylesView: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "Styles",
                detail: "Choose how your words are formatted in each kind of app."
            ) { EmptyView() }

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                    ForEach(DictationController.AppCategory.allCases) { category in
                        styleCard(category)
                    }
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 30)
            }
        }
    }

    private func styleCard(_ category: DictationController.AppCategory) -> some View {
        let selection = controller.style(for: category)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: category.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OmilTheme.signal)
                    .frame(width: 34, height: 34)
                    .background(OmilTheme.signal.opacity(0.1), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.rawValue)
                        .font(.system(size: 14, weight: .semibold))
                    Text(appExamples(for: category))
                        .font(.system(size: 11))
                        .foregroundStyle(OmilTheme.muted)
                }
                Spacer()
            }

            OmilPickerField(
                title: "Writing style",
                selection: Binding(
                    get: { controller.style(for: category) },
                    set: { controller.setStyle($0, for: category) }
                ),
                options: styles(for: category),
                label: { $0.displayName }
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("Example")
                    .font(OmilType.utility(9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(OmilTheme.faint)
                Text(preview(for: selection))
                    .font(.system(size: 13))
                    .foregroundStyle(OmilTheme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(OmilTheme.canvas, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 224, alignment: .topLeading)
        .background(OmilTheme.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(OmilTheme.line))
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

    var body: some View {
        let keys = controller.dictionaryEntries.keys.sorted()
        VStack(spacing: 0) {
            PageHeader(
                title: "Dictionary",
                detail: "Correct names and words that Omil mishears."
            ) { EmptyView() }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .bottom, spacing: 12) {
                        LabeledField(label: "When I say", placeholder: "oh mill", text: $spoken)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(OmilTheme.faint)
                            .padding(.bottom, 12)
                        LabeledField(label: "Write instead", placeholder: "Omil", text: $written)
                        Button("Add word") { addWord() }
                            .buttonStyle(SignalButtonStyle())
                            .disabled(spoken.trimmed.isEmpty || written.trimmed.isEmpty)
                    }
                    .padding(18)
                    .background(OmilTheme.panel, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(OmilTheme.line))

                    Text("\(controller.dictionaryEntries.count) corrections")
                        .font(OmilType.utility(10, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(OmilTheme.muted)

                    if keys.isEmpty {
                        EmptyState(
                            icon: "character.book.closed",
                            title: "No corrections yet",
                            detail: "Enter the word Omil gets wrong and how it should be spelled."
                        )
                        .frame(minHeight: 280)
                    } else {
                        ForEach(keys, id: \.self) { key in
                            HStack(spacing: 18) {
                                Text(key)
                                    .foregroundStyle(OmilTheme.muted)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(OmilTheme.faint)
                                Text(controller.dictionaryEntries[key] ?? "")
                                    .fontWeight(.semibold)
                                Spacer()
                                Button(role: .destructive) {
                                    controller.deleteDictionaryEntry(spoken: key)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(OmilTheme.faint)
                                .help("Delete correction")
                            }
                            .font(.system(size: 13))
                            .padding(.horizontal, 16)
                            .frame(height: 48)
                            .background(OmilTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(OmilTheme.line))
                        }
                    }
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 30)
            }
        }
    }

    private func addWord() {
        let source = spoken.trimmed
        let replacement = written.trimmed
        guard !source.isEmpty, !replacement.isEmpty else { return }
        controller.confirmDictionary(spoken: source, written: replacement)
        spoken = ""
        written = ""
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
    @State private var showAdvanced = false
    @State private var modelPendingDeletion: ModelOption?
    @State private var confirmTokenRotation = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "Speech engine",
                detail: "Manage the models that transcribe and edit your speech."
            ) {
                EmptyView()
            }

            ScrollView {
                VStack(spacing: 16) {
                    EngineStatusBar(controller: controller)
                    if !controller.usesCustomServer {
                        switch controller.toolInstallState {
                        case .idle, .ready:
                            EmptyView()
                        case .installing(let formulae):
                            Label("Installing \(formulae.joined(separator: " and ")) with Homebrew. This may take a few minutes.", systemImage: "arrow.down.circle")
                                .font(.system(size: 12))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(OmilTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                        case .failed(let message, let homebrewMissing):
                            VStack(alignment: .leading, spacing: 10) {
                                Label(message, systemImage: "exclamationmark.triangle")
                                    .font(.system(size: 12, weight: .medium))
                                if homebrewMissing {
                                    Link("Install Homebrew", destination: URL(string: "https://brew.sh/")!)
                                        .font(.system(size: 12, weight: .semibold))
                                    Text("After installing Homebrew, run this command in Terminal:")
                                        .font(.system(size: 11))
                                } else {
                                    Text("You can run this command in Terminal:")
                                        .font(.system(size: 11))
                                }
                                HStack {
                                    Text(LocalServerManager.manualInstallCommand)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                    Spacer()
                                    Button("Copy") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(LocalServerManager.manualInstallCommand, forType: .string)
                                    }
                                    .buttonStyle(QuietButtonStyle())
                                    Button("Retry") { controller.retryInferenceToolInstall() }
                                        .buttonStyle(QuietButtonStyle())
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(OmilTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }

                    VStack(spacing: 0) {
                        ModelPipelineRow(
                            stage: "Transcription",
                            detail: "Turns speech into text",
                            icon: "waveform",
                            selection: Binding(
                                get: { controller.displayedWhisperFile },
                                set: { controller.chooseWhisperModel(file: $0) }
                            ),
                            activeFile: controller.whisperFile,
                            options: whisperModelOptions,
                            downloaded: controller.modelIsDownloaded(file: controller.displayedWhisperFile),
                            fileState: controller.modelInfo(file: controller.displayedWhisperFile)?.fileState,
                            receivedBytes: controller.modelInfo(file: controller.displayedWhisperFile)?.receivedBytes,
                            totalBytes: controller.modelInfo(file: controller.displayedWhisperFile)?.totalBytes,
                            memoryState: controller.modelInfo(file: controller.displayedWhisperFile)?.memoryState,
                            downloading: controller.modelIsDownloading(file: controller.displayedWhisperFile),
                            interactionDisabled: controller.modelsPreparing,
                            download: { controller.downloadModel(file: controller.displayedWhisperFile) }
                        )
                        Divider()
                            .overlay(OmilTheme.line)
                            .padding(.leading, 68)
                        ModelPipelineRow(
                            stage: "Cleanup",
                            detail: "Removes filler words and fixes punctuation",
                            icon: "wand.and.stars",
                            selection: Binding(
                                get: { controller.displayedLLMFile },
                                set: { controller.chooseLLMModel(file: $0) }
                            ),
                            activeFile: controller.llmFile,
                            options: rewriteModelOptions,
                            downloaded: controller.modelIsDownloaded(file: controller.displayedLLMFile),
                            fileState: controller.modelInfo(file: controller.displayedLLMFile)?.fileState,
                            receivedBytes: controller.modelInfo(file: controller.displayedLLMFile)?.receivedBytes,
                            totalBytes: controller.modelInfo(file: controller.displayedLLMFile)?.totalBytes,
                            memoryState: controller.modelInfo(file: controller.displayedLLMFile)?.memoryState,
                            downloading: controller.modelIsDownloading(file: controller.displayedLLMFile),
                            interactionDisabled: controller.modelsPreparing,
                            download: { controller.downloadModel(file: controller.displayedLLMFile) }
                        )
                    }
                    .background(OmilTheme.panel, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(OmilTheme.line))

                    ModelLibraryCard(controller: controller) { modelPendingDeletion = $0 }

                    LANSharingCard(
                        controller: controller,
                        confirmTokenRotation: $confirmTokenRotation
                    )

                    DisclosureGroup(isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Use this only when this Mac should connect to a different Omil server.")
                                .font(.system(size: 11))
                                .foregroundStyle(OmilTheme.muted)
                            HStack {
                                LabeledField(label: "HOST", placeholder: "192.168.1.20", text: $controller.externalServerConfig.host)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text("PORT")
                                        .font(OmilType.utility(9, weight: .bold))
                                        .tracking(0.8)
                                        .foregroundStyle(OmilTheme.faint)
                                    TextField("3217", value: $controller.externalServerConfig.port, format: .number)
                                        .textFieldStyle(OmilTextFieldStyle())
                                        .frame(width: 90)
                                }
                            }
                            VStack(alignment: .leading, spacing: 7) {
                                Text("SERVER TOKEN")
                                    .font(OmilType.utility(9, weight: .bold))
                                    .tracking(0.8)
                                    .foregroundStyle(OmilTheme.faint)
                                SecureField("Token from the other server", text: $controller.externalServerConfig.token)
                                    .textFieldStyle(OmilTextFieldStyle())
                            }
                            HStack {
                                Label("Audio and text go to this address", systemImage: "lock.shield")
                                    .font(.system(size: 11))
                                    .foregroundStyle(OmilTheme.muted)
                                Spacer()
                                if controller.usesCustomServer {
                                    Button("Use local server") { controller.useManagedServer() }
                                        .buttonStyle(QuietButtonStyle())
                                }
                                Button(controller.usesCustomServer ? "Update server" : "Use this server") {
                                    controller.saveServerConfig()
                                }
                                    .buttonStyle(SignalButtonStyle())
                            }
                        }
                        .padding(.top, 14)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: controller.usesCustomServer ? "network" : "macbook")
                                .foregroundStyle(OmilTheme.signal)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Connect to another server")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(controller.usesCustomServer ? "Active" : "Advanced")
                                    .font(.system(size: 11))
                                    .foregroundStyle(OmilTheme.muted)
                            }
                            Spacer()
                            Text(verbatim: "\(controller.serverConfig.host):\(controller.serverConfig.port)")
                                .font(OmilType.utility(10, weight: .medium))
                                .foregroundStyle(OmilTheme.faint)
                        }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(18)
                    .background(OmilTheme.panelDeep, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(OmilTheme.line))

                    if !controller.serverOpNote.isEmpty || !controller.serverNote.isEmpty {
                        Label(
                            controller.serverOpNote.isEmpty ? controller.serverNote : controller.serverOpNote,
                            systemImage: "info.circle"
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(OmilTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 30)
            }
        }
        .task {
            while !Task.isCancelled {
                await controller.fetchServerModels()
                do {
                    try await Task.sleep(for: .seconds(1))
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
                Button("Delete model", role: .destructive) {
                    controller.deleteModel(file: model.file)
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
            Button("Replace token", role: .destructive) {
                controller.regenerateLANToken()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Devices using the current token will disconnect until you enter the new one.")
        }
    }
}

private struct ModelLibraryCard: View {
    @ObservedObject var controller: DictationController
    let requestDelete: (ModelOption) -> Void
    @State private var showsAll = false

    private var actionsLocked: Bool {
        controller.phase == .recording || controller.phase == .preparing ||
        !controller.processingJobs.isEmpty || controller.modelsPreparing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model library")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OmilTheme.ink)
                    Text(controller.usesCustomServer ? "Models on the connected server" : "Models stored on this Mac")
                        .font(.system(size: 11))
                        .foregroundStyle(OmilTheme.muted)
                }
                Spacer()
                HStack(spacing: 3) {
                    Button("Installed") { showsAll = false }
                        .buttonStyle(SegmentButtonStyle(selected: !showsAll))
                    Button("All models") { showsAll = true }
                        .buttonStyle(SegmentButtonStyle(selected: showsAll))
                }
            }
            .padding(18)

            Divider().overlay(OmilTheme.line)

            if controller.serverModels.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking available models")
                        .font(.system(size: 12))
                        .foregroundStyle(OmilTheme.muted)
                }
                .padding(18)
            } else {
                group(title: "Transcription", icon: "waveform", options: whisperModelOptions,
                      activeFile: controller.whisperFile, isWhisper: true)
                Divider().overlay(OmilTheme.line)
                group(title: "Cleanup", icon: "wand.and.stars", options: rewriteModelOptions,
                      activeFile: controller.llmFile, isWhisper: false)
            }
        }
        .background(OmilTheme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(OmilTheme.line))
    }

    private func group(title: String, icon: String, options: [ModelOption],
                       activeFile: String, isWhisper: Bool) -> some View {
        let installed = options.filter { controller.modelIsDownloaded(file: $0.file) == true }
        let visible = showsAll ? options : options.filter {
            controller.modelIsDownloaded(file: $0.file) == true ||
            controller.modelInfo(file: $0.file)?.fileState == "failed" ||
            controller.modelIsDownloading(file: $0.file) ||
            controller.modelInfo(file: $0.file)?.fileState == "downloading" ||
            controller.modelInfo(file: $0.file)?.fileState == "verifying"
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(OmilTheme.signal)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OmilTheme.ink)
                Spacer()
                Text("\(installed.count) installed")
                    .font(OmilType.utility(10))
                    .foregroundStyle(OmilTheme.muted)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .background(OmilTheme.panelDeep.opacity(0.5))

            if visible.isEmpty {
                Text("No \(title.lowercased()) models installed. Choose All models to download one.")
                    .font(.system(size: 11))
                    .foregroundStyle(OmilTheme.muted)
                    .padding(18)
            } else {
                ForEach(visible, id: \.file) { option in
                    modelRow(option, activeFile: activeFile, isWhisper: isWhisper)
                    if option.file != visible.last?.file {
                        Divider().overlay(OmilTheme.line)
                            .padding(.leading, 18)
                    }
                }
            }
        }
    }

    private func modelRow(_ option: ModelOption, activeFile: String, isWhisper: Bool) -> some View {
        let info = controller.modelInfo(file: option.file)
        let isActive = option.file == activeFile
        let isDownloading = controller.modelIsDownloading(file: option.file) ||
            info?.fileState == "downloading" || info?.fileState == "verifying"
        let needsRepair = info?.fileState == "failed" && info?.downloaded != true
        let isSelected = isActive && info?.downloaded == true
        return HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isSelected ? OmilTheme.mint : .clear)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(option.name)
                    .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(OmilTheme.ink)
                    .lineLimit(1)
                    .help(info?.description ?? option.name)
                Text(status(for: info, isActive: isActive, isDownloading: isDownloading))
                    .font(.system(size: 10))
                    .foregroundStyle(needsRepair ? OmilTheme.warning : OmilTheme.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(option.size)
                .font(OmilType.utility(10))
                .foregroundStyle(OmilTheme.faint)
                .fixedSize()
            if isDownloading {
                ProgressView().controlSize(.small)
                    .frame(width: 78)
            } else if isSelected {
                Text("In use")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(OmilTheme.mint)
                    .frame(width: 78, alignment: .trailing)
            } else if info?.downloaded == true {
                Button("Select") {
                    if isWhisper { controller.chooseWhisperModel(file: option.file) }
                    else { controller.chooseLLMModel(file: option.file) }
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(actionsLocked)
                .frame(width: 78)
            } else {
                Button(needsRepair ? "Repair" : "Download") {
                    controller.downloadModel(file: option.file)
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(actionsLocked || info == nil)
                .frame(width: 78)
            }
            if info?.downloaded == true && !isActive {
                Button { requestDelete(option) } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .frame(width: 25, height: 25)
                }
                .buttonStyle(.plain)
                .foregroundStyle(OmilTheme.faint)
                .disabled(actionsLocked)
                .help("Delete \(option.name)")
                .accessibilityLabel("Delete \(option.name)")
            } else {
                Color.clear.frame(width: 25, height: 25)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(isActive ? OmilTheme.mint.opacity(0.035) : .clear)
    }

    private func status(for info: DictationController.ServerModelInfo?, isActive: Bool,
                        isDownloading: Bool) -> String {
        guard let info else { return "Checking availability" }
        if isDownloading {
            if let received = info.receivedBytes, let total = info.totalBytes, total > 0 {
                return "Downloading · \(min(100, Int(Double(received) / Double(total) * 100)))%"
            }
            return "Downloading"
        }
        if info.fileState == "failed" { return info.fileError ?? "Model needs repair" }
        if info.downloaded { return isActive ? "Selected for dictation" : "Installed and ready to select" }
        return "Available to download"
    }
}

private struct LANSharingCard: View {
    @ObservedObject var controller: DictationController
    @Binding var confirmTokenRotation: Bool
    @State private var revealToken = false
    @State private var showPairingCode = false

    private var connectionLocked: Bool {
        controller.phase == .recording
            || controller.phase == .preparing
            || controller.phase == .processing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(controller.lanSharingEnabled
                              ? OmilTheme.mint.opacity(0.12)
                              : OmilTheme.panelLifted)
                    Image(systemName: controller.lanSharingEnabled ? "network" : "network.slash")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(controller.lanSharingEnabled ? OmilTheme.mint : OmilTheme.muted)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Share with your devices")
                        .font(.system(size: 13, weight: .semibold))
                    Text(controller.lanSharingEnabled
                         ? "iPhone and iPad can use this Mac's engine"
                         : "Only this Mac can use your speech models")
                        .font(.system(size: 11))
                        .foregroundStyle(OmilTheme.muted)
                }
                Spacer()
                Toggle("Share on local network", isOn: Binding(
                    get: { controller.lanSharingEnabled },
                    set: { controller.setLANSharing($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(controller.usesCustomServer || connectionLocked)
                .help("Allow authenticated devices on this local network to use Omil")
            }

            if controller.usesCustomServer {
                Label("Switch to this Mac to share its engine.", systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(OmilTheme.muted)
            } else if controller.lanSharingEnabled {
                Divider().overlay(OmilTheme.line)
                if let credentials = controller.lanCredentials {
                    VStack(spacing: 10) {
                        CredentialRow(label: "ADDRESS", value: credentials.endpoint)
                        CredentialRow(
                            label: "TOKEN",
                            value: revealToken ? credentials.token : String(repeating: "•", count: 24)
                        )
                    }
                    HStack {
                        Label("Only share this token with devices you trust.", systemImage: "lock.shield")
                            .font(.system(size: 11))
                            .foregroundStyle(OmilTheme.muted)
                        Spacer()
                        Button(revealToken ? "Hide token" : "Show token") {
                            revealToken.toggle()
                        }
                        .buttonStyle(QuietButtonStyle())
                        Button("New token") { confirmTokenRotation = true }
                            .buttonStyle(QuietButtonStyle())
                            .disabled(connectionLocked)
                        Button("Pair iPhone") { showPairingCode = true }
                            .buttonStyle(QuietButtonStyle())
                        Button("Copy setup") { controller.copyLANCredentials() }
                            .buttonStyle(SignalButtonStyle())
                    }
                } else {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text("Restarting the engine for local network access")
                            .font(.system(size: 11))
                            .foregroundStyle(OmilTheme.muted)
                    }
                }
            }
        }
        .padding(18)
        .background(OmilTheme.panelDeep, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(controller.lanSharingEnabled ? OmilTheme.mint.opacity(0.35) : OmilTheme.line)
        )
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

    private var code: NSImage? {
        guard let url = ServerConfig(host: credentials.host, port: credentials.port, token: credentials.token).pairingURL,
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let context = CIContext()
        guard let output = filter.outputImage,
              let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Connect your iPhone")
                .font(OmilType.display(20))
                .foregroundStyle(OmilTheme.ink)
            Text("In Omil on iPhone, open Settings and tap Scan QR code.")
                .font(.system(size: 12))
                .foregroundStyle(OmilTheme.muted)
            if let code {
                Image(nsImage: code)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 224, height: 224)
                    .padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Omil server pairing QR code")
            }
            Text(verbatim: credentials.endpoint)
                .font(OmilType.utility(11))
                .foregroundStyle(OmilTheme.faint)
            Text("This code contains your server token. Show it only to devices you trust.")
                .font(.system(size: 11))
                .foregroundStyle(OmilTheme.muted)
            Button("Done") { dismiss() }
                .buttonStyle(QuietButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 340)
        .omilAppearance()
    }
}

private struct CredentialRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 14) {
            Text(label)
                .font(OmilType.utility(9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(OmilTheme.faint)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(OmilTheme.ink)
                .lineLimit(1)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(OmilTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(OmilTheme.line))
    }
}

private struct EngineStatusBar: View {
    @ObservedObject var controller: DictationController

    private var healthy: Bool { controller.serverIsReady }
    private var preparing: Bool {
        controller.modelsPreparing
            || !controller.downloadingModelIDs.isEmpty
            || controller.serverHealth.localizedCaseInsensitiveContains("starting")
            || controller.serverHealth.localizedCaseInsensitiveContains("restarting")
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(healthy ? OmilTheme.mint : preparing ? OmilTheme.signal : OmilTheme.warning)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 4) {
                Text(healthy ? "Ready for dictation" : preparing ? "Preparing models" : "Setup needed")
                    .font(.system(size: 14, weight: .semibold))
                Text(controller.speechSetupSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(OmilTheme.muted)
            }
            Spacer()
            if ["loading", "ready", "inUse", "unloading"].contains(controller.selectedLLMMemoryState) {
                Button(controller.selectedLLMMemoryState == "inUse" ? "Release after use" : "Free memory") {
                    controller.unloadModels()
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(controller.selectedLLMMemoryState == "unloading")
            }
            if !controller.usesCustomServer {
                Button("Restart") { controller.restartManagedServer() }
                    .buttonStyle(QuietButtonStyle())
            }
            if controller.modelIsDownloaded(file: controller.llmFile) == true {
                Button(controller.reloadingLLM ? "Reloading…" : "Reload cleanup") {
                    controller.reloadCleanupModel()
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(controller.reloadingLLM || !controller.processingJobs.isEmpty ||
                          !controller.downloadingModelIDs.isEmpty)
                .help("Restart the selected cleanup model on the server")
            }
            Button("Check now") { Task { await controller.refreshServerHealth() } }
                .buttonStyle(QuietButtonStyle())
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }
}

private struct ModelPipelineRow: View {
    let stage: String
    let detail: String
    let icon: String
    @Binding var selection: String
    let activeFile: String
    let options: [ModelOption]
    let downloaded: Bool?
    let fileState: String?
    let receivedBytes: Int?
    let totalBytes: Int?
    let memoryState: String?
    let downloading: Bool
    let interactionDisabled: Bool
    let download: () -> Void

    private var selectedOption: ModelOption? {
        options.first(where: { $0.file == selection })
    }

    private var downloadPercent: Int? {
        guard let receivedBytes, let totalBytes, totalBytes > 0 else { return nil }
        return min(100, max(0, Int((Double(receivedBytes) / Double(totalBytes)) * 100)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                PipelineNode(icon: icon, ready: downloaded == true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(stage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OmilTheme.ink)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(OmilTheme.muted)
                }
                Spacer(minLength: 12)
                Text(selectedOption?.size ?? "")
                    .font(OmilType.utility(10, weight: .medium))
                    .foregroundStyle(OmilTheme.muted)
            }
            HStack(spacing: 14) {
                OmilPickerField(
                    title: stage + " model",
                    selection: $selection,
                    options: options.map(\.file),
                    label: { file in options.first(where: { $0.file == file })?.name ?? file },
                    markedSelection: activeFile
                )
                .disabled(interactionDisabled)
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 7) {
                    if fileState == "downloading" || downloading {
                        ProgressView()
                            .controlSize(.small)
                        Text(downloadPercent.map { "\($0)%" } ?? "Downloading")
                            .foregroundStyle(OmilTheme.muted)
                    } else if fileState == "verifying" {
                        ProgressView()
                            .controlSize(.small)
                        Text("Verifying")
                            .foregroundStyle(OmilTheme.muted)
                    } else if fileState == "checking" {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking")
                            .foregroundStyle(OmilTheme.muted)
                    } else if downloaded == true {
                        memoryStatus
                    } else if fileState == "failed" {
                        Button("Repair", action: download)
                            .buttonStyle(SignalButtonStyle())
                            .disabled(interactionDisabled)
                    } else if downloaded == false {
                        Button("Download", action: download)
                            .buttonStyle(SignalButtonStyle())
                            .disabled(interactionDisabled)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking")
                            .foregroundStyle(OmilTheme.muted)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .frame(width: 124, alignment: .trailing)
                .frame(minHeight: 34)
            }
            .padding(.leading, 48)
            if selection != activeFile {
                Text("Current: \(options.first(where: { $0.file == activeFile })?.name ?? activeFile)")
                    .font(.system(size: 10))
                    .foregroundStyle(OmilTheme.muted)
                    .padding(.leading, 48)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var memoryStatus: some View {
        switch memoryState {
        case "loading":
            ProgressView().controlSize(.small)
            Text("Loading").foregroundStyle(OmilTheme.muted)
        case "ready":
            Circle().fill(OmilTheme.mint).frame(width: 7, height: 7)
            Text("Loaded").foregroundStyle(OmilTheme.muted)
        case "inUse":
            Circle().fill(OmilTheme.signal).frame(width: 7, height: 7)
            Text("In use").foregroundStyle(OmilTheme.muted)
        case "unloading":
            ProgressView().controlSize(.small)
            Text("Releasing").foregroundStyle(OmilTheme.muted)
        case "failed":
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(OmilTheme.warning)
            Text("Load failed").foregroundStyle(OmilTheme.muted)
        default:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(OmilTheme.mint)
            Text("On demand").foregroundStyle(OmilTheme.muted)
        }
    }
}

private struct PipelineNode: View {
    let icon: String
    let ready: Bool

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ready ? OmilTheme.mint : OmilTheme.muted)
            .frame(width: 34, height: 34)
            .background(OmilTheme.line, in: RoundedRectangle(cornerRadius: 9))
            .accessibilityHidden(true)
    }
}

// MARK: - Reusable pieces

private struct PageHeader<Accessory: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(OmilType.display(28))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(OmilTheme.muted)
            }
            Spacer()
            accessory()
        }
        .padding(.horizontal, 30)
        .padding(.top, 28)
        .padding(.bottom, 22)
    }
}

private struct EmptyState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(OmilTheme.signal)
            Text(title)
                .font(OmilType.display(18))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(OmilTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct LabeledField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(OmilType.utility(9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(OmilTheme.faint)
            TextField(placeholder, text: $text)
                .accessibilityLabel(label)
                .textFieldStyle(OmilTextFieldStyle())
        }
        .frame(maxWidth: .infinity)
    }
}

private struct StatusLabel: View {
    let phase: DictationController.Phase
    let environmentReady: Bool

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.6), radius: 4)
            Text(label)
                .font(OmilType.utility(9, weight: .bold))
                .tracking(1)
                .foregroundStyle(OmilTheme.muted)
        }
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
        .frame(width: 160)
        .controlSize(.small)
    }
}

private struct ProcessingTrack: View {
    let stage: DictationController.ProcessingStage

    var body: some View {
        HStack(spacing: 10) {
            ForEach(DictationController.ProcessingStage.allCases.filter { $0 != .queued }, id: \.rawValue) { item in
                if item != .transcribing {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(OmilTheme.faint)
                }
                HStack(spacing: 6) {
                    Image(systemName: item.rawValue < stage.rawValue ? "checkmark.circle.fill" : item.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(item.rawValue <= stage.rawValue ? OmilTheme.signal : OmilTheme.faint)
                    Text(item.title)
                        .font(.system(size: 11, weight: item == stage ? .semibold : .medium))
                        .foregroundStyle(item == stage ? OmilTheme.ink : OmilTheme.muted)
                }
                .opacity(item.rawValue <= stage.rawValue ? 1 : 0.55)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Processing: \(stage.title)")
    }
}

struct LiveSignalRail: View {
    @ObservedObject var meter: AudioMeter

    var body: some View {
        SignalRail(levels: meter.levels, active: true)
    }
}

struct SignalRail: View {
    let levels: [Double]
    let active: Bool

    var body: some View {
        Canvas { context, size in
            let visible = levels.suffix(36)
            guard !visible.isEmpty else { return }
            let spacing: CGFloat = 4
            let width = max(1, (size.width - CGFloat(visible.count - 1) * spacing) / CGFloat(visible.count))
            for (index, level) in visible.enumerated() {
                let height = barHeight(level: level, available: size.height)
                let rect = CGRect(x: CGFloat(index) * (width + spacing),
                                  y: (size.height - height) / 2,
                                  width: width, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: min(width, height) / 2),
                             with: .color(barColor(level: level)))
            }
        }
        .accessibilityHidden(true)
    }

    private func barHeight(level: Double, available: CGFloat) -> CGFloat {
        let value = min(1, max(0, level))
        return max(3, 3 + available * 0.9 * value)
    }

    private func barColor(level: Double) -> Color {
        guard active else { return OmilTheme.lineStrong }
        return OmilTheme.signal.opacity(0.42 + min(1, max(0, level)) * 0.58)
    }
}

private struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(OmilType.utility(9, weight: .bold))
            .foregroundStyle(OmilTheme.ink)
            .padding(.horizontal, 9)
            .frame(height: 23)
            .background(OmilTheme.panelLifted, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(OmilTheme.lineStrong))
    }
}

private struct EngineStatusRow: View {
    @ObservedObject var controller: DictationController

    private var healthy: Bool { controller.serverIsReady }

    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(healthy ? OmilTheme.mint : OmilTheme.warning).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(healthy ? "Ready to transcribe" : "Check speech setup")
                    .font(.system(size: 11, weight: .semibold))
            }
            Spacer()
        }
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
                .frame(width: 27, height: 25)
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? OmilTheme.faint.opacity(0.5) : OmilTheme.muted)
        .disabled(disabled)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct SignalButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(OmilTheme.signalInk)
            .padding(.horizontal, 15)
            .frame(height: 34)
            .background(OmilTheme.signal.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 9))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(OmilTheme.ink)
            .padding(.horizontal, 11)
            .frame(height: 29)
            .background(OmilTheme.panelLifted.opacity(configuration.isPressed ? 0.65 : 1), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(OmilTheme.lineStrong))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

struct OmilPickerField<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    var markedSelection: Value? = nil
    @State private var isPresented = false
    @State private var attachmentPoint = UnitPoint(x: 0.5, y: 1)
    @State private var pointerTapPending = false

    var body: some View {
        GeometryReader { geometry in
        Button {
            // A keyboard press has no pointer location. The mouse gesture below
            // updates the anchor before the deferred presentation runs.
            DispatchQueue.main.async {
                if !pointerTapPending {
                    attachmentPoint = UnitPoint(x: 0.5, y: 1)
                }
                pointerTapPending = false
                isPresented = true
            }
        } label: {
            HStack(spacing: 10) {
                Text(label(selection))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(OmilTheme.ink)
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(OmilTheme.panelDeep, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(OmilTheme.lineStrong))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(SpatialTapGesture().onEnded { value in
            let x = min(max(value.location.x / max(geometry.size.width, 1), 0), 1)
            pointerTapPending = true
            attachmentPoint = UnitPoint(x: x, y: 1)
        })
        .popover(isPresented: $isPresented, attachmentAnchor: .point(attachmentPoint), arrowEdge: .bottom) {
            VStack(spacing: 2) {
                ForEach(options, id: \.self) { option in
                    Button {
                        selection = option
                        isPresented = false
                    } label: {
                        HStack(spacing: 12) {
                            Text(label(option))
                            Spacer(minLength: 12)
                            if option == (markedSelection ?? selection) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(OmilTheme.signal)
                            }
                        }
                        .font(.system(size: 12, weight: option == (markedSelection ?? selection) ? .semibold : .medium))
                        .foregroundStyle(OmilTheme.ink)
                        .padding(.horizontal, 11)
                        .frame(height: 32)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(option == (markedSelection ?? selection) ? OmilTheme.panelLifted : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(HoverButtonStyle(cornerRadius: 7))
                }
            }
            .padding(7)
            .frame(minWidth: 190)
            .background(OmilTheme.panel, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(OmilTheme.lineStrong))
            .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
        }
        .accessibilityLabel(title)
        .accessibilityValue(label(selection))
        }
        .frame(height: 32)
    }
}

struct HoverButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 8

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
                isEnabled && (hovered || configuration.isPressed) ? OmilTheme.panelLifted : .clear,
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .onHover { hovered = $0 }
    }
}

private struct SidebarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SidebarButtonBody(configuration: configuration)
    }
}

private struct SidebarButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(hovered ? OmilTheme.ink : OmilTheme.muted)
            .padding(.horizontal, 9)
            .frame(height: 34)
            .background(hovered || configuration.isPressed ? OmilTheme.panelLifted : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .onHover { hovered = $0 }
    }
}

private struct SegmentButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? OmilTheme.ink : OmilTheme.muted)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(selected ? OmilTheme.panelLifted : .clear, in: RoundedRectangle(cornerRadius: 7))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct OmilTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        let canvas = MainActor.assumeIsolated { OmilTheme.canvas }
        let lineStrong = MainActor.assumeIsolated { OmilTheme.lineStrong }
        return configuration
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(canvas, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(lineStrong))
    }
}

enum OmilType {
    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }

    static func utility(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

@MainActor
enum OmilTheme {
    private static var palette: ThemePalette {
        AppAppearance.shared.themePreset.palette(for: AppAppearance.shared.colorScheme)
    }

    static var canvas: Color { Color(hex: palette.canvas) }
    static var sidebar: Color { Color(hex: palette.sidebar) }
    static var panel: Color { Color(hex: palette.panel) }
    static var panelDeep: Color { Color(hex: palette.panelDeep) }
    static var panelLifted: Color { Color(hex: palette.panelLifted) }
    static var line: Color { Color(hex: palette.line) }
    static var lineStrong: Color { Color(hex: palette.lineStrong) }
    static var ink: Color { Color(hex: palette.ink) }
    static var muted: Color { Color(hex: palette.muted) }
    static var faint: Color { Color(hex: palette.faint) }
    static var signal: Color { Color(hex: palette.signal) }
    static var signalInk: Color { Color(hex: palette.signalInk) }
    static var violet: Color { signal }
    static var coral: Color { adaptive(light: 0xB8474F, dark: 0xDB6469) }
    static var mint: Color { adaptive(light: 0x287A59, dark: 0x72B392) }
    static var warning: Color { adaptive(light: 0x94651E, dark: 0xD1A15A) }

    private static func adaptive(light: UInt, dark: UInt) -> Color {
        Color(hex: AppAppearance.shared.colorScheme == .dark ? dark : light)
    }
}

struct ThemePalette {
    let canvas: UInt
    let sidebar: UInt
    let panel: UInt
    let panelDeep: UInt
    let panelLifted: UInt
    let line: UInt
    let lineStrong: UInt
    let ink: UInt
    let muted: UInt
    let faint: UInt
    let signal: UInt
    let signalInk: UInt
}

extension ThemePreset {
    func palette(for scheme: ColorScheme) -> ThemePalette {
        switch (self, scheme) {
        case (.studio, .light):
            return ThemePalette(canvas: 0xF5F5F3, sidebar: 0xECECEA, panel: 0xFFFFFF,
                                panelDeep: 0xF0F0EE, panelLifted: 0xE7E7E4, line: 0xDDDDDA,
                                lineStrong: 0xC6C6C2, ink: 0x1C1D1F, muted: 0x626367,
                                faint: 0x6E7075, signal: 0x25272B, signalInk: 0xFFFFFF)
        case (.studio, .dark):
            return ThemePalette(canvas: 0x000000, sidebar: 0x050505, panel: 0x0A0A0A,
                                panelDeep: 0x050505, panelLifted: 0x171717, line: 0x242424,
                                lineStrong: 0x333333, ink: 0xEDEDED, muted: 0xA1A1A1,
                                faint: 0x949494, signal: 0xEDEDED, signalInk: 0x17181A)
        case (.fog, .light):
            return ThemePalette(canvas: 0xF4F5F6, sidebar: 0xEAEDEF, panel: 0xFFFFFF,
                                panelDeep: 0xF0F2F3, panelLifted: 0xE4E8EA, line: 0xD8DEE1,
                                lineStrong: 0xB8C2C7, ink: 0x242A2E, muted: 0x566168,
                                faint: 0x657077, signal: 0x3E5D6A, signalInk: 0xFFFFFF)
        case (.fog, .dark):
            return ThemePalette(canvas: 0x1B1E21, sidebar: 0x202428, panel: 0x262B2F,
                                panelDeep: 0x21262A, panelLifted: 0x323A3F, line: 0x394248,
                                lineStrong: 0x526069, ink: 0xF1F4F5, muted: 0xB5C0C5,
                                faint: 0x9FADB3, signal: 0xA6D2DC, signalInk: 0x193039)
        case (.slate, .light):
            return ThemePalette(canvas: 0xF2F4F7, sidebar: 0xE7EBF1, panel: 0xFCFDFE,
                                panelDeep: 0xEBEFF4, panelLifted: 0xDEE5EE, line: 0xD2DBE5,
                                lineStrong: 0xB6C3D1, ink: 0x293443, muted: 0x5B6878,
                                faint: 0x687587, signal: 0x4C617E, signalInk: 0xFFFFFF)
        case (.slate, .dark):
            return ThemePalette(canvas: 0x14171C, sidebar: 0x191E25, panel: 0x202731,
                                panelDeep: 0x1A212A, panelLifted: 0x2C3743, line: 0x34414F,
                                lineStrong: 0x4D6074, ink: 0xF0F4F8, muted: 0xB2BFCE,
                                faint: 0x9AABBD, signal: 0xA4BEFF, signalInk: 0x18253E)
        case (.linen, .light):
            return ThemePalette(canvas: 0xF8F6F1, sidebar: 0xF0EDE6, panel: 0xFFFEFB,
                                panelDeep: 0xF3F0E9, panelLifted: 0xEAE5DA, line: 0xDDD7CB,
                                lineStrong: 0xC6BBAA, ink: 0x342F2A, muted: 0x696057,
                                faint: 0x746B61, signal: 0x765D48, signalInk: 0xFFFFFF)
        case (.linen, .dark):
            return ThemePalette(canvas: 0x191817, sidebar: 0x201F1D, panel: 0x272522,
                                panelDeep: 0x22201E, panelLifted: 0x35312C, line: 0x3F3A34,
                                lineStrong: 0x5D554B, ink: 0xF5F1EB, muted: 0xC5BCB0,
                                faint: 0xAEA396, signal: 0xE7BC8F, signalInk: 0x352516)
        case (.tide, .light):
            return ThemePalette(canvas: 0xF0F6F5, sidebar: 0xE5EFED, panel: 0xFCFFFE,
                                panelDeep: 0xEAF3F1, panelLifted: 0xDDEBE8, line: 0xD1E1DE,
                                lineStrong: 0xB0CBC5, ink: 0x263A3B, muted: 0x586D6D,
                                faint: 0x657979, signal: 0x376E70, signalInk: 0xFFFFFF)
        case (.tide, .dark):
            return ThemePalette(canvas: 0x141B1D, sidebar: 0x1A2325, panel: 0x202C2F,
                                panelDeep: 0x1B2528, panelLifted: 0x2C3B3E, line: 0x35474A,
                                lineStrong: 0x4C6768, ink: 0xEDF5F3, muted: 0xB3CBC8,
                                faint: 0x9AB7B3, signal: 0x8DDAD2, signalInk: 0x163734)
        case (.clay, .light):
            return ThemePalette(canvas: 0xF8F4F3, sidebar: 0xF1EAE8, panel: 0xFFFEFD,
                                panelDeep: 0xF5EEEC, panelLifted: 0xEDE1DF, line: 0xE1D3D0,
                                lineStrong: 0xCAB5B0, ink: 0x3D3032, muted: 0x705F62,
                                faint: 0x7A696B, signal: 0x895A64, signalInk: 0xFFFFFF)
        case (.clay, .dark):
            return ThemePalette(canvas: 0x19171A, sidebar: 0x201D21, panel: 0x282329,
                                panelDeep: 0x221E23, panelLifted: 0x352E35, line: 0x40363F,
                                lineStrong: 0x604E59, ink: 0xF7F0F2, muted: 0xCEBCC4,
                                faint: 0xB9A4AE, signal: 0xF0A9BE, signalInk: 0x3B1D2B)
        case (.lilac, .light):
            return ThemePalette(canvas: 0xF6F4F8, sidebar: 0xEEEBF2, panel: 0xFFFEFF,
                                panelDeep: 0xF1EEF5, panelLifted: 0xE7E1EC, line: 0xDBD4E2,
                                lineStrong: 0xC1B5CC, ink: 0x342F3C, muted: 0x665F70,
                                faint: 0x746C7D, signal: 0x6C5B80, signalInk: 0xFFFFFF)
        case (.lilac, .dark):
            return ThemePalette(canvas: 0x17161C, sidebar: 0x1D1B23, panel: 0x25222D,
                                panelDeep: 0x1F1D26, panelLifted: 0x322E3D, line: 0x3D374A,
                                lineStrong: 0x5A4E6A, ink: 0xF5F1F8, muted: 0xC9BFD4,
                                faint: 0xB2A4C3, signal: 0xCDB2FF, signalInk: 0x2A1944)
        case (.moss, .light):
            return ThemePalette(canvas: 0xF3F6F2, sidebar: 0xE9EFE7, panel: 0xFDFFFC,
                                panelDeep: 0xEEF3EC, panelLifted: 0xE0EADD, line: 0xD3E0D0,
                                lineStrong: 0xB6C9B2, ink: 0x2B392F, muted: 0x5E7061,
                                faint: 0x6A7C6D, signal: 0x4D7154, signalInk: 0xFFFFFF)
        case (.moss, .dark):
            return ThemePalette(canvas: 0x151A17, sidebar: 0x1B221E, panel: 0x232C26,
                                panelDeep: 0x1D251F, panelLifted: 0x303C33, line: 0x39483D,
                                lineStrong: 0x536958, ink: 0xF0F6F0, muted: 0xBCD0C0,
                                faint: 0xA3BBA8, signal: 0xA9DDB3, signalInk: 0x1D3925)
        @unknown default:
            return ThemePreset.studio.palette(for: .light)
        }
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
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
