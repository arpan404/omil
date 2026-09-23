import AppKit
import SwiftUI
import OmilCore

// MARK: - Product shell

@MainActor
final class AppAppearance: ObservableObject {
    static let shared = AppAppearance()
    @Published private(set) var colorScheme: ColorScheme
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
    @ObservedObject private var appearance = AppAppearance.shared

    func body(content: Content) -> some View {
        content.environment(\.colorScheme, appearance.colorScheme)
            .modifier(PointerAwareFocus())
    }
}

extension View {
    func omilAppearance() -> some View { modifier(AppAppearanceModifier()) }
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
    @ObservedObject var controller: DictationController

    var body: some View {
        Group {
            if controller.onboarded {
                MainWindowView(controller: controller)
            } else {
                OnboardingView(controller: controller)
            }
        }
        .frame(minWidth: 760, minHeight: 540)
        .omilAppearance()
    }
}

struct MainWindowView: View {
    @ObservedObject var controller: DictationController
    @Environment(\.openSettings) private var openSettings
    @State private var section: MainSection? = .record

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(OmilTheme.signal)
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
                    openSettings()
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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if showsHeader { RecorderHeader(controller: controller) }

                if controller.micPermission != .granted {
                    PermissionStrip(controller: controller)
                }

                recorderColumn
            }
            .padding(showsHeader ? 30 : 0)
        }
        .onChange(of: controller.phase) { _, phase in
            if phase == .recording, startedAt == nil { startedAt = Date() }
            if phase != .recording { startedAt = nil }
            if phase == .ready { resultTab = .clean }
        }
    }

    private var recorderColumn: some View {
        VStack(spacing: 16) {
            RecorderStage(controller: controller, startedAt: startedAt)
            if !controller.lastCleaned.isEmpty || !controller.lastRaw.isEmpty || !controller.lastDiff.isEmpty {
                ResultCard(controller: controller, selectedTab: $resultTab)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct RecorderHeader: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Dictate")
                .font(OmilType.display(31))
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
            .padding(.horizontal, 20)
            .padding(.top, 18)

            Spacer(minLength: 12)

            Group {
                if active {
                    SignalRail(levels: controller.audioLevels, active: true)
                } else if controller.phase == .processing {
                    ProcessingTrack(stage: controller.processingStage)
                } else {
                    Color.clear
                }
            }
            .frame(height: 52)
            .padding(.horizontal, 42)

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
                            .stroke(active ? OmilTheme.coral.opacity(0.28) : OmilTheme.lineStrong, lineWidth: 1)
                            .frame(width: 76, height: 76)
                        Circle()
                            .fill(active ? OmilTheme.coral : OmilTheme.signal)
                            .frame(width: 58, height: 58)
                            .shadow(color: OmilTheme.ink.opacity(0.1), radius: 10, y: 4)
                        Image(systemName: active ? "stop.fill" : "mic.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(active ? Color.white : OmilTheme.signalInk)
                    }
                }
                .buttonStyle(.plain)
                .disabled(busy || !controller.serverIsReady)
                .accessibilityLabel(active ? "Stop recording" : "Start recording")
            }

            VStack(spacing: 5) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(primaryStatus)
                        .font(OmilType.display(18))
                        .contentTransition(.numericText())
                }
                if !secondaryStatus.isEmpty {
                    Text(secondaryStatus)
                        .font(.system(size: 12))
                        .foregroundStyle(OmilTheme.muted)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }
            .padding(.top, 8)

            Spacer(minLength: 14)

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
            .tracking(0.5)
            .foregroundStyle(OmilTheme.muted)
            .padding(.bottom, 20)
        }
        .frame(minHeight: 276)
        .background(OmilTheme.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(OmilTheme.lineStrong))
        .clipShape(RoundedRectangle(cornerRadius: 16))
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
        case .ready: return controller.lastCleaned.isEmpty ? "Nothing heard" : "Ready"
        case .failed: return "Needs attention"
        }
    }

    private var secondaryStatus: String {
        switch controller.phase {
        case .idle: return controller.micPermission != .granted ? "Allow microphone access to start transcribing." : controller.serverIsReady ? "Click the microphone to dictate into your last text field, or use the shortcut without switching apps." : "Open Engine to check your speech models."
        case .recording: return controller.draftText.isEmpty ? "Listening for your voice" : controller.draftText
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
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(OmilTheme.mint)
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

    private var resultText: String {
        switch selectedTab {
        case .clean: return controller.lastCleaned.isEmpty ? "Your transcript will appear here." : controller.lastCleaned
        case .raw: return controller.lastRaw.isEmpty ? "The unedited transcript will appear here." : controller.lastRaw
        case .changes: return controller.lastDiff.isEmpty ? "Edits to your original transcript will appear here." : controller.lastDiff
        }
    }
}

// MARK: - History

struct HistoryView: View {
    @ObservedObject var controller: DictationController
    @State private var search = ""
    @State private var confirmDelete: DictationController.HistoryEntry?
    @State private var confirmRecoveryDelete: RecoveryRecording?
    @State private var selectedTranscript: HistoryTranscript?

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase }

    private var filteredRecordings: [RecoveryRecording] {
        guard !query.isEmpty else { return controller.recoveryRecordings }
        return controller.recoveryRecordings.filter {
            ($0.transcript ?? "").localizedLowercase.contains(query) ||
            ($0.rawTranscript ?? "").localizedLowercase.contains(query)
        }
    }

    private var filtered: [(day: Date, entries: [DictationController.HistoryEntry])] {
        guard !query.isEmpty else { return controller.historyByDay }
        return controller.historyByDay.compactMap { day, entries in
            let matches = entries.filter {
                $0.cleaned.localizedLowercase.contains(query) || $0.raw.localizedLowercase.contains(query)
            }
            return matches.isEmpty ? nil : (day, matches)
        }
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
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if !filteredRecordings.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
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
                                ForEach(filteredRecordings) { recording in
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
                                }
                            }
                        }

                        if filtered.isEmpty {
                            if filteredRecordings.isEmpty && !query.isEmpty {
                                EmptyState(icon: "magnifyingglass", title: "Nothing matched", detail: "Try a shorter word or phrase.")
                            }
                        } else {
                        ForEach(filtered, id: \.day) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(controller.dayLabel(for: group.day).uppercased())
                                    .font(OmilType.utility(10, weight: .bold))
                                    .tracking(1)
                                    .foregroundStyle(OmilTheme.muted)
                                ForEach(group.entries) { entry in
                                    HistoryCard(
                                        entry: entry,
                                        copy: { copy(entry.cleaned) },
                                        viewTranscript: { selectedTranscript = HistoryTranscript(entry: entry) },
                                        delete: { confirmDelete = entry }
                                    )
                                }
                            }
                        }
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.bottom, 30)
                }
            }
        }
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
                            Picker("Speed", selection: $playback.rate) {
                                Text("0.75×").tag(Float(0.75))
                                Text("1×").tag(Float(1))
                                Text("1.25×").tag(Float(1.25))
                                Text("1.5×").tag(Float(1.5))
                                Text("2×").tag(Float(2))
                            }
                            .labelsHidden()
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
                Text(transcript)
                    .font(.system(size: 12))
                    .foregroundStyle(OmilTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
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
            Text(entry.cleaned)
                .font(.system(size: 15))
                .foregroundStyle(OmilTheme.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

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
                VStack(alignment: .leading, spacing: 18) {
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
                        LazyVStack(spacing: 10) {
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

            Picker("Writing style", selection: Binding(
                get: { controller.style(for: category) },
                set: { controller.setStyle($0, for: category) }
            )) {
                ForEach(styles(for: category), id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

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
        VStack(spacing: 0) {
            PageHeader(
                title: "Dictionary",
                detail: "Correct names and words that Omil mishears."
            ) { EmptyView() }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
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

                    if controller.dictionaryEntries.isEmpty {
                        EmptyState(
                            icon: "character.book.closed",
                            title: "No corrections yet",
                            detail: "Enter the word Omil gets wrong and how it should be spelled."
                        )
                        .frame(minHeight: 280)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(controller.dictionaryEntries.keys.sorted()), id: \.self) { key in
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
                                if key != controller.dictionaryEntries.keys.sorted().last {
                                    Divider().overlay(OmilTheme.line).padding(.leading, 16)
                                }
                            }
                        }
                        .background(OmilTheme.panel, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(OmilTheme.line))
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
    ModelOption(file: "ggml-tiny.bin", name: "Whisper tiny", size: "77 MB"),
    ModelOption(file: "ggml-base.bin", name: "Whisper base", size: "148 MB"),
    ModelOption(file: "ggml-small.bin", name: "Whisper small", size: "488 MB"),
    ModelOption(file: "ggml-medium.bin", name: "Whisper medium", size: "1.5 GB"),
    ModelOption(file: "ggml-medium-32-2.en.bin", name: "Distil-Whisper medium · English", size: "794 MB"),
    ModelOption(file: "ggml-distil-large-v3.bin", name: "Distil-Whisper large-v3 · English", size: "1.5 GB"),
    ModelOption(file: "ggml-large-v3-turbo-q5_0.bin", name: "Whisper large-v3 turbo Q5", size: "574 MB"),
    ModelOption(file: "ggml-large-v3-turbo-q8_0.bin", name: "Whisper large-v3 turbo Q8", size: "874 MB"),
    ModelOption(file: "ggml-large-v3-turbo.bin", name: "Whisper large-v3 turbo", size: "1.6 GB"),
    ModelOption(file: "ggml-large-v3-q5_0.bin", name: "Whisper large-v3 Q5", size: "1.1 GB"),
    ModelOption(file: "ggml-large-v3.bin", name: "Whisper large-v3", size: "3.1 GB")
]

private let rewriteModelOptions = [
    ModelOption(file: "Qwen3-0.6B-Q4_K_M.gguf", name: "Qwen3 0.6B", size: "397 MB"),
    ModelOption(file: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf", name: "Qwen3 4B", size: "2.5 GB"),
    ModelOption(file: "Qwen3-8B-Q4_K_M.gguf", name: "Qwen3 8B", size: "5 GB"),
    ModelOption(file: "Qwen3.5-0.8B-Q4_K_M.gguf", name: "Qwen3.5 0.8B", size: "533 MB"),
    ModelOption(file: "Qwen3.5-4B-Q4_K_M.gguf", name: "Qwen3.5 4B", size: "2.7 GB"),
    ModelOption(file: "Qwen3.5-9B-Q4_K_M.gguf", name: "Qwen3.5 9B", size: "5.7 GB")
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

                    VStack(spacing: 0) {
                        ModelPipelineRow(
                            stage: "Transcription",
                            detail: "Turns speech into text",
                            icon: "waveform",
                            selection: Binding(
                                get: { controller.displayedWhisperFile },
                                set: { controller.chooseWhisperModel(file: $0) }
                            ),
                            options: whisperModelOptions,
                            downloaded: controller.modelIsDownloaded(file: controller.displayedWhisperFile),
                            fileState: controller.modelInfo(file: controller.displayedWhisperFile)?.fileState,
                            receivedBytes: controller.modelInfo(file: controller.displayedWhisperFile)?.receivedBytes,
                            totalBytes: controller.modelInfo(file: controller.displayedWhisperFile)?.totalBytes,
                            memoryState: controller.modelInfo(file: controller.displayedWhisperFile)?.memoryState,
                            downloading: controller.modelIsDownloading(file: controller.displayedWhisperFile),
                            interactionDisabled: controller.modelsPreparing || !controller.downloadingModelIDs.isEmpty,
                            download: { controller.downloadModel(file: controller.displayedWhisperFile) },
                            delete: {
                                modelPendingDeletion = whisperModelOptions.first {
                                    $0.file == controller.displayedWhisperFile
                                }
                            }
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
                            options: rewriteModelOptions,
                            downloaded: controller.modelIsDownloaded(file: controller.displayedLLMFile),
                            fileState: controller.modelInfo(file: controller.displayedLLMFile)?.fileState,
                            receivedBytes: controller.modelInfo(file: controller.displayedLLMFile)?.receivedBytes,
                            totalBytes: controller.modelInfo(file: controller.displayedLLMFile)?.totalBytes,
                            memoryState: controller.modelInfo(file: controller.displayedLLMFile)?.memoryState,
                            downloading: controller.modelIsDownloading(file: controller.displayedLLMFile),
                            interactionDisabled: controller.modelsPreparing || !controller.downloadingModelIDs.isEmpty,
                            download: { controller.downloadModel(file: controller.displayedLLMFile) },
                            delete: {
                                modelPendingDeletion = rewriteModelOptions.first {
                                    $0.file == controller.displayedLLMFile
                                }
                            }
                        )
                    }
                    .background(OmilTheme.panel, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(OmilTheme.line))

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
            Text("This deletes the model from this Mac. You can download it again later.")
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

private struct LANSharingCard: View {
    @ObservedObject var controller: DictationController
    @Binding var confirmTokenRotation: Bool
    @State private var revealToken = false

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
    let options: [ModelOption]
    let downloaded: Bool?
    let fileState: String?
    let receivedBytes: Int?
    let totalBytes: Int?
    let memoryState: String?
    let downloading: Bool
    let interactionDisabled: Bool
    let download: () -> Void
    let delete: () -> Void

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
                Picker(stage + " model", selection: $selection) {
                    ForEach(options, id: \.file) { option in
                        Text(option.name).tag(option.file)
                    }
                }
                .labelsHidden()
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
                        Button("Retry", action: download)
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
                    if downloaded == true {
                        Button(action: delete) {
                            Image(systemName: "trash")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(OmilTheme.faint)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .disabled(interactionDisabled)
                        .help("Delete downloaded model")
                        .accessibilityLabel("Delete " + stage.lowercased() + " model")
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .frame(width: 124, alignment: .trailing)
                .frame(minHeight: 34)
            }
            .padding(.leading, 48)
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
            ForEach(DictationController.ProcessingStage.allCases, id: \.rawValue) { item in
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

struct SignalRail: View {
    let levels: [Double]
    let active: Bool

    var body: some View {
        GeometryReader { proxy in
            let visible = Array(levels.suffix(36))
            HStack(alignment: .center, spacing: 4) {
                ForEach(Array(visible.enumerated()), id: \.offset) { item in
                    Capsule()
                        .fill(barColor(level: item.element))
                        .frame(maxWidth: .infinity)
                        .frame(height: barHeight(level: item.element, available: proxy.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(OmilTheme.muted)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(configuration.isPressed ? OmilTheme.panelLifted : .clear, in: RoundedRectangle(cornerRadius: 7))
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
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(OmilTheme.canvas, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(OmilTheme.lineStrong))
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

enum OmilTheme {
    static let canvas = adaptive(light: 0xF5F5F3, dark: 0x000000)
    static let sidebar = adaptive(light: 0xECECEA, dark: 0x050505)
    static let panel = adaptive(light: 0xFFFFFF, dark: 0x0A0A0A)
    static let panelDeep = adaptive(light: 0xF0F0EE, dark: 0x050505)
    static let panelLifted = adaptive(light: 0xE7E7E4, dark: 0x171717)
    static let line = adaptive(light: 0xDDDDDA, dark: 0x242424)
    static let lineStrong = adaptive(light: 0xC6C6C2, dark: 0x333333)
    static let ink = adaptive(light: 0x1C1D1F, dark: 0xEDEDED)
    static let muted = adaptive(light: 0x626367, dark: 0xA1A1A1)
    static let faint = adaptive(light: 0x6E7075, dark: 0x949494)
    static let signal = adaptive(light: 0x25272B, dark: 0xEDEDED)
    static let signalInk = adaptive(light: 0xFFFFFF, dark: 0x17181A)
    static let violet = signal
    static let coral = adaptive(light: 0xB8474F, dark: 0xDB6469)
    static let mint = adaptive(light: 0x287A59, dark: 0x72B392)
    static let warning = adaptive(light: 0x94651E, dark: 0xD1A15A)

    private static func adaptive(light: UInt, dark: UInt) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        })
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

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
