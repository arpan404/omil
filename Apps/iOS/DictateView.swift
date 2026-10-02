import SwiftUI
import OmilCore
import OmilDesign

enum TranscriptVersion: String, CaseIterable, Identifiable {
    case clean = "Clean"
    case original = "Original"
    case changes = "Changes"

    var id: String { rawValue }
}

/// Home, laid out like Notes and Voice Memos: your words are the page, and
/// the record control is docked at the bottom.
struct DictateView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @Environment(\.omil) private var colors
    @Environment(\.scenePhase) private var scenePhase
    @State private var version: TranscriptVersion = .clean
    @State private var showSettings = DebugLaunch.screen != nil && DebugLaunch.screen != "history"
    @State private var showConnection = false
    @State private var showHistory = DebugLaunch.screen == "history"
    @State private var recordingStart: Date?
    @State private var levels = [Double](repeating: 0, count: Waveform.barCount)
    @State private var retrying = false

    private var phase: SessionCoordinator.Phase { coordinator.phase }
    private var isRecording: Bool { phase == .recording }
    private var hasResult: Bool { !coordinator.lastCleaned.isEmpty }

    var body: some View {
        NavigationStack {
            Group {
                if coordinator.needsMacSetup {
                    ScrollView {
                        setupHero
                            .padding(24)
                            .frame(maxWidth: .infinity)
                            .containerRelativeFrame(.vertical, alignment: .center)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .transition(.opacity)
                } else {
                    page
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            RecordBar(coordinator: coordinator, levels: levels, recordingStart: recordingStart)
                        }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 10) {
                    if !coordinator.needsMacSetup, let notice = coordinator.engineNotice {
                        NoticeCard(notice: notice, retrying: retrying, retry: retry)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if coordinator.micSessionEnds != nil {
                        MicSessionBanner(coordinator: coordinator)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .frame(maxWidth: 680)
            }
            .background(colors.canvas.ignoresSafeArea())
            .navigationTitle("Dictate")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showHistory = true } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel("History")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .animation(Motion.standard, value: phase)
            .animation(Motion.standard, value: coordinator.needsMacSetup)
            .animation(Motion.standard, value: coordinator.engineNotice)
            .animation(Motion.standard, value: coordinator.micSessionEnds == nil)
            .sensoryFeedback(trigger: phase) { old, new in
                switch (old, new) {
                case (_, .recording): return .impact(weight: .medium)
                case (_, .ready): return .success
                case (_, .failed): return .error
                case (.recording, .idle): return .impact(weight: .light)
                default: return nil
                }
            }
            .onChange(of: phase) { _, new in
                if new == .recording {
                    recordingStart = .now
                    levels = [Double](repeating: 0, count: Waveform.barCount)
                } else {
                    recordingStart = nil
                }
                if new == .ready { version = .clean }
            }
            .onChange(of: coordinator.audioLevel) { _, level in
                guard isRecording else { return }
                levels.removeFirst()
                levels.append(level)
            }
            .onChange(of: coordinator.pairingRequested) { _, requested in
                guard requested else { return }
                coordinator.pairingRequested = false
                showSettings = false
                showHistory = false
                showConnection = true
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active, !DebugLaunch.isDemo else { return }
                Task { await coordinator.refreshStatus() }
            }
            .task {
                guard !DebugLaunch.isDemo else { return }
                await coordinator.refreshStatus()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(coordinator: coordinator)
                    .themed()
                    .toastHost()
            }
            .sheet(isPresented: $showHistory) {
                HistoryView()
                    .themed()
                    .toastHost()
            }
            .sheet(isPresented: $showConnection) {
                NavigationStack {
                    ConnectionSettingsView(coordinator: coordinator, showsDone: true)
                }
                .themed()
                .toastHost()
            }
        }
    }

    // MARK: Page

    @ViewBuilder
    private var page: some View {
        switch phase {
        case .recording, .preparing:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Label(phase == .preparing ? "Starting" : "Listening", systemImage: "waveform")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(colors.recording)
                        .symbolEffect(.variableColor.iterative, isActive: isRecording)
                    Text(coordinator.draftText.isEmpty ? "Start talking. Your words appear here." : coordinator.draftText)
                        .font(.title3)
                        .foregroundStyle(coordinator.draftText.isEmpty ? colors.faint : colors.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentTransition(.opacity)
                        .animation(Motion.quick, value: coordinator.draftText)
                }
                .pagePadding()
            }
            .transition(.opacity)
        case .processing:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Cleaning up on your Mac")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(colors.muted)
                    }
                    Text(coordinator.draftText.isEmpty ? "Your words will appear here in a moment." : coordinator.draftText)
                        .font(.title3)
                        .foregroundStyle(colors.faint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .pagePadding()
            }
            .transition(.opacity)
        case .idle, .ready, .failed:
            if hasResult {
                result
                    .transition(.opacity)
            } else {
                ContentUnavailableView {
                    Label("Nothing Dictated Yet", systemImage: "waveform")
                } description: {
                    Text("Tap the record button and start talking. Omil cleans up your words on your Mac.\n\nIn other apps, use the Omil keyboard.")
                }
                .transition(.opacity)
            }
        }
    }

    private var result: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Version", selection: $version.animation(Motion.quick)) {
                    ForEach(TranscriptVersion.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                transcriptText
                    .id(version)
                    .transition(.opacity)
                HStack(spacing: 10) {
                    Button { ToastCenter.shared.copy(shareText) } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: shareText) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                .buttonStyle(OmilButtonStyle(kind: .secondary, fullWidth: false))
                .controlSize(.small)
                if coordinator.keyboardResultPending {
                    Label("Also ready on the Omil keyboard in any app.", systemImage: "keyboard")
                        .font(.footnote)
                        .foregroundStyle(colors.muted)
                }
            }
            .pagePadding()
        }
    }

    private var setupHero: some View {
        let rejected = coordinator.macConnection == .tokenRejected
        return VStack(spacing: 18) {
            HeroTile(symbol: "laptopcomputer.and.iphone", color: colors.signal, foreground: colors.signalInk)
                .padding(.bottom, 4)
            Text(rejected ? "Pair Again With Your Mac" : "Dictate With Your Mac")
                .font(.title2.bold())
                .foregroundStyle(colors.ink)
                .multilineTextAlignment(.center)
            Text(rejected
                 ? "Your Mac no longer accepts this iPhone. Scan a new pairing code in Omil on your Mac."
                 : "Omil uses your Mac for speech recognition and cleanup. Open Omil on your Mac, then scan its pairing code.")
                .font(.body)
                .foregroundStyle(colors.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { showConnection = true } label: {
                Label("Connect to Your Mac", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(OmilButtonStyle())
            .padding(.top, 10)
        }
        .frame(maxWidth: 420)
    }

    private func retry() {
        retrying = true
        Task {
            await coordinator.refreshStatus()
            retrying = false
        }
    }

    // MARK: Transcript

    @ViewBuilder
    private var transcriptText: some View {
        Group {
            switch version {
            case .clean:
                Text(coordinator.lastCleaned)
            case .original:
                Text(originalText)
            case .changes:
                if originalText == coordinator.lastCleaned {
                    Text("No changes. Omil kept your words as spoken.")
                        .foregroundStyle(colors.muted)
                } else {
                    GitDiffView(raw: originalText, cleaned: coordinator.lastCleaned,
                                removed: colors.recording, added: colors.success,
                                font: .system(.callout, design: .monospaced))
                }
            }
        }
        .font(.title3)
        .foregroundStyle(colors.ink)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var originalText: String {
        coordinator.lastRaw.isEmpty ? coordinator.lastCleaned : coordinator.lastRaw
    }

    private var shareText: String {
        version == .original ? originalText : coordinator.lastCleaned
    }
}

private extension View {
    /// Readable line length on iPad, Notes-like margins on iPhone.
    func pagePadding() -> some View {
        padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Record bar

/// Docked at the bottom like Voice Memos: the red record button, which turns
/// into Stop; while listening, the time and a live waveform above it.
private struct RecordBar: View {
    @ObservedObject var coordinator: SessionCoordinator
    let levels: [Double]
    let recordingStart: Date?
    @Environment(\.omil) private var colors

    private var phase: SessionCoordinator.Phase { coordinator.phase }
    private var recording: Bool { phase == .recording }

    var body: some View {
        VStack(spacing: 12) {
            if recording {
                VStack(spacing: 8) {
                    if let recordingStart { ElapsedTime(start: recordingStart) }
                    Waveform(levels: levels, color: colors.recording)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if phase == .failed {
                Label(coordinator.statusMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(colors.warning)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
            HStack {
                leading
                    .frame(width: 96, alignment: .leading)
                Spacer()
                RecordButton(phase: phase, action: primaryAction)
                Spacer()
                Color.clear.frame(width: 96, height: 1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .animation(Motion.standard, value: phase)
    }

    @ViewBuilder
    private var leading: some View {
        if recording {
            Button("Cancel", role: .cancel) { coordinator.cancel() }
                .font(.body.weight(.medium))
                .foregroundStyle(colors.ink)
        } else {
            Menu {
                Picker("Mode", selection: Binding(get: { coordinator.cleanupMode }, set: { coordinator.setMode($0) })) {
                    Label("Clean", systemImage: "wand.and.stars").tag(CleanupMode.clean)
                    Label("Verbatim", systemImage: "text.quote").tag(CleanupMode.verbatim)
                }
            } label: {
                HStack(spacing: 4) {
                    Text(coordinator.cleanupMode == .clean ? "Clean" : "Verbatim")
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .font(.body.weight(.medium))
                .foregroundStyle(colors.ink)
            }
            .disabled(phase == .processing || phase == .preparing)
            .accessibilityLabel("Mode: \(coordinator.cleanupMode == .clean ? "Clean" : "Verbatim")")
        }
    }

    private func primaryAction() {
        switch phase {
        case .recording: coordinator.stop()
        case .idle, .ready, .failed: coordinator.start()
        case .preparing, .processing: break
        }
    }
}

/// The record button from Voice Memos: a red circle in a ring that becomes a
/// rounded square to stop.
private struct RecordButton: View {
    let phase: SessionCoordinator.Phase
    let action: () -> Void
    @Environment(\.omil) private var colors

    private var recording: Bool { phase == .recording }
    private var busy: Bool { phase == .preparing || phase == .processing }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(colors.ink.opacity(colors.isDark ? 0.35 : 0.18), lineWidth: 4)
                if busy {
                    ProgressView()
                        .tint(colors.ink)
                } else {
                    RoundedRectangle(cornerRadius: recording ? 7 : 30, style: .continuous)
                        .fill(colors.recording)
                        .frame(width: recording ? 28 : 58, height: recording ? 28 : 58)
                }
            }
            .frame(width: 72, height: 72)
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .allowsHitTesting(!busy)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: recording)
        .accessibilityLabel(recording ? "Stop Recording" : busy ? "Working" : "Start Recording")
        .accessibilityHint(recording ? "Finishes and transcribes your dictation." : "")
    }
}

// MARK: - Pieces

struct ElapsedTime: View {
    let start: Date
    @Environment(\.omil) private var colors

    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(start)))
            Text(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)))
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(colors.ink)
                .contentTransition(.numericText(countsDown: false))
                .animation(Motion.standard, value: seconds)
                .accessibilityLabel("Recording time \(seconds) seconds")
        }
    }
}

struct Waveform: View {
    static let barCount = 32
    let levels: [Double]
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(color.opacity(0.35 + 0.65 * levels[index]))
                    .frame(width: 3, height: 4 + levels[index] * 32)
            }
        }
        .frame(height: 40)
        .accessibilityHidden(true)
    }
}

private struct NoticeCard: View {
    let notice: SessionCoordinator.EngineNotice
    let retrying: Bool
    let retry: () -> Void
    @Environment(\.omil) private var colors

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(colors.warning)
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title)
                    .font(.headline)
                    .foregroundStyle(colors.ink)
                Text(notice.detail)
                    .font(.subheadline)
                    .foregroundStyle(colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: retry) {
                    HStack(spacing: 6) {
                        Text(retrying ? "Checking…" : "Check Again")
                        if retrying { ProgressView().controlSize(.mini) }
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(colors.signal)
                .disabled(retrying)
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .groupedCard(colors)
        .accessibilityElement(children: .contain)
    }
}
