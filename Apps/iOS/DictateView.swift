import SwiftUI
import OmilCore

enum TranscriptVersion: String, CaseIterable, Identifiable {
    case clean = "Clean"
    case original = "Original"
    case changes = "Changes"

    var id: String { rawValue }
}

/// Home: one calm, centered record control, then the latest transcript.
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
    private var isBusy: Bool { phase == .preparing || phase == .processing }

    private var showsCard: Bool {
        guard !coordinator.needsMacSetup else { return false }
        switch phase {
        case .processing: return true
        case .recording: return !coordinator.draftText.isEmpty
        case .preparing: return false
        case .idle, .ready, .failed: return !coordinator.lastCleaned.isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 28) {
                        if coordinator.needsMacSetup {
                            setupHero
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        } else {
                            hero
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                        if showsCard {
                            transcriptCard
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height,
                           alignment: showsCard ? .top : .center)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if !coordinator.needsMacSetup, let notice = coordinator.engineNotice {
                    NoticeCard(notice: notice, retrying: retrying, retry: retry)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .frame(maxWidth: 620)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
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
            .animation(Motion.standard, value: showsCard)
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
                } else if new != .recording {
                    recordingStart = nil
                }
                if new == .ready { version = .clean }
            }
            .onChange(of: coordinator.audioLevel) { _, level in
                guard isRecording else { return }
                levels.removeFirst()
                levels.append(level)
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

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 8) {
            StatusChip(title: statusTitle, color: statusColor, pulsing: isRecording)
            RecordButton(phase: phase, level: coordinator.audioLevel, action: primaryAction)
            heroFooter
                .frame(minHeight: 44, alignment: .top)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var heroFooter: some View {
        switch phase {
        case .recording:
            VStack(spacing: 14) {
                if let recordingStart {
                    ElapsedTime(start: recordingStart)
                }
                Waveform(levels: levels, color: colors.recording)
                Button("Cancel", role: .cancel) { coordinator.cancel() }
                    .buttonStyle(OmilButtonStyle(kind: .secondary, fullWidth: false))
                    .controlSize(.small)
                    .padding(.top, 4)
            }
            .transition(.opacity)
        case .preparing:
            footnote("Starting the microphone…")
        case .processing:
            footnote("Transcribing and cleaning up…")
        case .failed:
            footnote(coordinator.statusMessage)
        case .idle, .ready:
            footnote(coordinator.lastCleaned.isEmpty ? "Tap to start dictating." : "Tap to dictate again.")
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(colors.muted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .contentTransition(.opacity)
            .transition(.opacity)
    }

    private func primaryAction() {
        switch phase {
        case .recording: coordinator.stop()
        case .idle, .ready, .failed: coordinator.start()
        case .preparing, .processing: break
        }
    }

    private var statusTitle: String {
        if coordinator.engineNotice != nil && !isRecording && !isBusy { return "Not Ready" }
        switch phase {
        case .idle, .ready: return "Ready"
        case .preparing: return "Starting"
        case .recording: return "Listening"
        case .processing: return "Transcribing"
        case .failed: return "Needs Attention"
        }
    }

    private var statusColor: Color {
        if coordinator.engineNotice != nil && !isRecording && !isBusy { return colors.warning }
        switch phase {
        case .idle, .ready: return colors.success
        case .preparing: return colors.faint
        case .recording: return colors.recording
        case .processing: return colors.signal
        case .failed: return colors.warning
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

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch phase {
            case .recording:
                Label("Live", systemImage: "waveform")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(colors.recording)
                    .symbolEffect(.variableColor.iterative, isActive: true)
                Text(coordinator.draftText)
                    .font(.body)
                    .foregroundStyle(colors.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .processing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(colors.muted)
                }
                Text("Your words will appear here as soon as your Mac finishes cleaning them up.")
                    .font(.body)
                    .redacted(reason: .placeholder)
                    .accessibilityHidden(true)
            default:
                Picker("Version", selection: $version.animation(Motion.quick)) {
                    ForEach(TranscriptVersion.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                transcriptText
                    .id(version)
                    .transition(.opacity)
                Divider()
                actions
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .groupedCard(colors)
    }

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
                    Text(TranscriptDiff.attributed(
                        TranscriptDiff.tokens(raw: originalText, cleaned: coordinator.lastCleaned),
                        added: colors.success, removed: colors.recording))
                }
            }
        }
        .font(.body)
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

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button { ToastCenter.shared.copy(shareText) } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                ShareLink(item: shareText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            .buttonStyle(OmilButtonStyle(kind: .secondary))
            .controlSize(.small)
            if coordinator.keyboardResultPending {
                Label("Ready to insert from the Omil keyboard.", systemImage: "keyboard")
                    .font(.footnote)
                    .foregroundStyle(colors.muted)
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - Pieces

private struct StatusChip: View {
    let title: String
    let color: Color
    let pulsing: Bool
    @Environment(\.omil) private var colors

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "circle.fill")
                .font(.caption2)
                .imageScale(.small)
                .foregroundStyle(color)
                .symbolEffect(.pulse, options: .repeating, isActive: pulsing)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(colors.ink)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background(colors.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(colors.line, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(title)")
    }
}

private struct RecordButton: View {
    let phase: SessionCoordinator.Phase
    let level: Double
    let action: () -> Void
    @Environment(\.omil) private var colors

    private var recording: Bool { phase == .recording }
    private var busy: Bool { phase == .preparing || phase == .processing }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(colors.recording.opacity(0.16))
                    .scaleEffect(recording ? 1.1 + level * 0.3 : 0.9)
                    .opacity(recording ? 1 : 0)
                Circle()
                    .fill(fill)
                if busy {
                    ProgressView()
                        .controlSize(.large)
                        .tint(colors.ink)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                } else {
                    Image(systemName: recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(recording ? .white : colors.signalInk)
                        .contentTransition(.symbolEffect(.replace))
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .frame(width: 128, height: 128)
            .padding(24)
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .allowsHitTesting(!busy)
        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: level)
        .animation(Motion.standard, value: phase)
        .accessibilityLabel(recording ? "Stop Recording" : busy ? "Working" : "Start Recording")
        .accessibilityHint(recording ? "Finishes and transcribes your dictation." : "")
    }

    private var fill: Color {
        if recording { return colors.recording }
        if busy { return colors.panelLifted }
        return colors.signal
    }
}

private struct ElapsedTime: View {
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
