import AppKit
import Combine
import SwiftUI
import OmilCore

// MARK: - Floating dictation control

private enum PillLayout {
    static func size(for phase: DictationController.Phase) -> NSSize {
        switch phase {
        case .idle: return NSSize(width: 78, height: 32)
        case .preparing: return NSSize(width: 126, height: 38)
        case .recording: return NSSize(width: 138, height: 40)
        case .processing: return NSSize(width: 130, height: 38)
        case .ready: return NSSize(width: 142, height: 36)
        case .failed: return NSSize(width: 130, height: 38)
        }
    }
}

struct PillVisibility {
    private(set) var hiddenForCurrentRecording = false
    private var lastPhase: DictationController.Phase = .idle

    mutating func observe(_ phase: DictationController.Phase, alwaysVisible: Bool = false) {
        if phase == .preparing && lastPhase != .preparing {
            hiddenForCurrentRecording = false
        }
        if alwaysVisible && (phase == .idle || phase == .ready || phase == .failed) {
            hiddenForCurrentRecording = false
        }
        lastPhase = phase
    }

    mutating func hide() {
        hiddenForCurrentRecording = true
    }
}

/// Persist the bottom center, which stays fixed as the pill changes size.
struct PillPosition {
    private(set) var anchor: NSPoint?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let value = defaults.string(forKey: "omil.pillAnchor") {
            anchor = NSPointFromString(value)
        } else if let value = defaults.string(forKey: "omil.pillPosition") {
            let origin = NSPointFromString(value)
            anchor = NSPoint(x: origin.x + 80, y: origin.y)
        }
    }

    mutating func remember(_ frame: NSRect) {
        let point = NSPoint(x: frame.midX, y: frame.minY)
        anchor = point
        defaults.set(NSStringFromPoint(point), forKey: "omil.pillAnchor")
    }

    func frame(size: NSSize, fallback: NSPoint, screens: [NSRect]) -> NSRect {
        let point = anchor ?? fallback
        var frame = NSRect(x: point.x - size.width / 2, y: point.y, width: size.width, height: size.height)
        guard let screen = screens.first(where: { $0.contains(point) })
            ?? screens.first(where: { $0.intersects(frame) })
            ?? screens.first else { return frame }
        let bounds = screen.insetBy(dx: 8, dy: 8)
        frame.origin.x = max(bounds.minX, min(frame.minX, bounds.maxX - size.width))
        frame.origin.y = max(bounds.minY, min(frame.minY, bounds.maxY - size.height))
        return frame
    }
}

@MainActor
final class PillManager: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = PillManager()

    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private weak var controller: DictationController?
    private var presentation: PillPresentation?
    private var dismissTask: Task<Void, Never>?
    private var visibility = PillVisibility()

    private var position = PillPosition()
    private var placingPanel = false

    private override init() { super.init() }

    func debugInfo() -> String {
        guard let p = panel else { return "no panel" }
        return "panel visible=\(p.isVisible)"
    }

    func attach(_ controller: DictationController) {
        if panel != nil { return }
        self.controller = controller
        let presentation = PillPresentation(controller: controller)
        self.presentation = presentation
        let view = PillView(presentation: presentation)
        let hosting = NSHostingView(rootView: view)
        let initialSize = PillLayout.size(for: controller.phase)
        hosting.frame = NSRect(origin: .zero, size: initialSize)
        hosting.autoresizingMask = [.width, .height]
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        p.contentView = hosting
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        p.hasShadow = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hidesOnDeactivate = false
        p.animationBehavior = .utilityWindow
        p.isReleasedWhenClosed = false
        p.alphaValue = 0.72
        self.panel = p
        resize(p, to: initialSize)
        p.delegate = self
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                guard let self, let panel = self.panel else { return }
                self.resize(panel, to: panel.frame.size)
            }.store(in: &cancellables)
        controller.$phase.sink { [weak self] phase in
            self?.reflect(phase: phase)
        }.store(in: &cancellables)
        controller.$pillEnabled.sink { [weak self] enabled in
            guard let self, let c = self.controller else { return }
            self.reflect(phase: c.phase, pillEnabled: enabled)
        }.store(in: &cancellables)
        controller.$pillAlwaysVisible.sink { [weak self] alwaysVisible in
            guard let self, let c = self.controller else { return }
            self.reflect(phase: c.phase, alwaysVisible: alwaysVisible, pillEnabled: c.pillEnabled)
        }.store(in: &cancellables)
        controller.$processingJobs.sink { [weak self] jobs in
            guard let self, let c = self.controller else { return }
            self.reflect(phase: c.phase, pendingCount: jobs.count)
        }.store(in: &cancellables)
    }

    private func reflect(
        phase: DictationController.Phase,
        alwaysVisible: Bool? = nil,
        pillEnabled: Bool? = nil,
        pendingCount: Int? = nil
    ) {
        guard let p = panel else { return }
        let always = alwaysVisible ?? controller?.pillAlwaysVisible ?? false
        visibility.observe(phase, alwaysVisible: always)
        let enabled = Self.isEligible(
            source: controller?.recordingSource ?? .app,
            enabled: pillEnabled ?? controller?.pillEnabled ?? true,
            alwaysVisible: always
        )
        dismissTask?.cancel()
        dismissTask = nil
        resize(p, to: PillLayout.size(for: phase))
        if visibility.hiddenForCurrentRecording {
            if p.isVisible { p.orderOut(nil) }
            return
        }
        switch phase {
        case .idle where enabled && always:
            if !p.isVisible {
                keepOnScreen(p)
                p.orderFrontRegardless()
            }
        case .preparing where enabled, .recording where enabled, .processing where enabled:
            if !p.isVisible {
                keepOnScreen(p)
                p.orderFrontRegardless()
            }
        case .ready where enabled:
            if !p.isVisible {
                keepOnScreen(p)
                p.orderFrontRegardless()
            }
            if !always && (pendingCount ?? controller?.processingJobs.count ?? 0) == 0 {
                dismissTask = Task { @MainActor [weak self, weak p] in
                    try? await Task.sleep(for: .seconds(1.4))
                    guard !Task.isCancelled,
                          self?.controller?.phase == .ready else { return }
                    p?.orderOut(nil)
                }
            }
        case .failed where enabled:
            if always && !p.isVisible { keepOnScreen(p) }
            if always || p.isVisible { p.orderFrontRegardless() }
        default:
            if p.isVisible { p.orderOut(nil) }
        }
    }

    private func resize(_ panel: NSPanel, to size: NSSize) {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let fallback = NSPoint(x: screen.midX, y: screen.minY + 24)
        let frame = position.frame(size: size, fallback: fallback, screens: NSScreen.screens.map(\.visibleFrame))
        guard panel.frame != frame else { return }
        placingPanel = true
        defer { placingPanel = false }
        panel.setFrame(frame, display: true)
    }

    func windowDidMove(_ notification: Notification) {
        guard !placingPanel, let panel else { return }
        position.remember(panel.frame)
    }

    static func isEligible(
        source: DictationController.RecordingSource,
        enabled: Bool,
        alwaysVisible: Bool = false
    ) -> Bool {
        enabled && (alwaysVisible || source == .shortcut || source == .menuBar || source == .pill)
    }

    func setHovered(_ hovered: Bool) {
        panel?.alphaValue = hovered ? 1 : 0.72
    }

    func drag(with event: NSEvent) {
        guard let panel else { return }
        panel.performDrag(with: event)
        position.remember(panel.frame)
        keepOnScreen(panel)
    }

    private func keepOnScreen(_ panel: NSPanel) {
        resize(panel, to: panel.frame.size)
    }

    func hideForCurrentRecording() {
        visibility.hide()
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
    }

    func hideFromContextMenu() {
        guard let controller else { return }
        if controller.pillAlwaysVisible {
            controller.setPillEnabled(false)
        } else {
            hideForCurrentRecording()
        }
    }
}

@MainActor
final class PillPresentation: ObservableObject {
    @Published private(set) var phase: DictationController.Phase
    @Published private(set) var processingStage: DictationController.ProcessingStage
    @Published private(set) var lastCleaned: String
    @Published private(set) var statusMessage: String
    @Published private(set) var audioLevels: [Double]
    @Published private(set) var pillAlwaysVisible: Bool
    @Published private(set) var pendingCount: Int
    @Published private(set) var pendingStage: DictationController.ProcessingStage?
    @Published private(set) var showCompletion = false

    private weak var controller: DictationController?
    private var cancellables = Set<AnyCancellable>()
    private var completionTask: Task<Void, Never>?

    init(controller: DictationController) {
        self.controller = controller
        phase = controller.phase
        processingStage = controller.processingStage
        lastCleaned = controller.lastCleaned
        statusMessage = controller.statusMessage
        audioLevels = controller.audioMeter.levels
        pillAlwaysVisible = controller.pillAlwaysVisible
        pendingCount = controller.processingJobs.count
        pendingStage = controller.processingJobs.first?.stage

        controller.$phase.sink { [weak self] phase in
            self?.phase = phase
            if phase == .recording || phase == .preparing {
                self?.completionTask?.cancel()
                self?.showCompletion = false
            }
        }.store(in: &cancellables)
        controller.$processingStage.sink { [weak self] in self?.processingStage = $0 }.store(in: &cancellables)
        controller.$lastCleaned.sink { [weak self] in self?.lastCleaned = $0 }.store(in: &cancellables)
        controller.$statusMessage.sink { [weak self] in self?.statusMessage = $0 }.store(in: &cancellables)
        controller.audioMeter.$levels.sink { [weak self] in self?.audioLevels = $0 }.store(in: &cancellables)
        controller.$pillAlwaysVisible.sink { [weak self] in self?.pillAlwaysVisible = $0 }.store(in: &cancellables)
        controller.$processingJobs.sink { [weak self] jobs in
            guard let self else { return }
            let hadPending = self.pendingCount > 0
            self.pendingCount = jobs.count
            self.pendingStage = jobs.first?.stage
            if hadPending && jobs.isEmpty && self.phase == .ready {
                self.showCompletion = true
                self.completionTask?.cancel()
                self.completionTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(1.4))
                    guard !Task.isCancelled else { return }
                    self?.showCompletion = false
                }
            }
        }.store(in: &cancellables)
    }

    func cancel() { controller?.cancel() }
    func stop() { controller?.stop() }
    func start() { controller?.start(source: .pill) }
}

@MainActor
struct PillView: View {
    @ObservedObject fileprivate var presentation: PillPresentation

    var body: some View {
        Group {
            switch presentation.phase {
            case .recording:
                recordingContent
            case .preparing:
                statusContent(icon: "mic.fill", title: "Starting", showsProgress: true, canCancel: true)
            case .processing:
                statusContent(
                    icon: presentation.processingStage.icon,
                    title: presentation.processingStage.title,
                    showsProgress: true,
                    canCancel: false
                )
            case .ready:
                if presentation.pendingCount == 0 && !presentation.showCompletion {
                    idleContent
                } else { statusContent(
                    icon: presentation.pendingCount > 0 ? "waveform" : presentation.lastCleaned.isEmpty ? "waveform.slash" : "checkmark",
                    title: presentation.pendingCount == 1 ? (presentation.pendingStage?.title ?? "Working") : presentation.pendingCount > 1 ? "\(presentation.pendingCount) active" : presentation.lastCleaned.isEmpty ? "No speech" : "Done",
                    showsProgress: presentation.pendingCount > 0,
                    canCancel: false,
                    canStart: presentation.pillAlwaysVisible || presentation.pendingCount > 0
                ) }
            case .failed:
                statusContent(
                    icon: "exclamationmark",
                    title: presentation.pillAlwaysVisible ? "Try again" : "Failed",
                    showsProgress: false,
                    canCancel: false,
                    canStart: presentation.pillAlwaysVisible
                )
            case .idle:
                idleContent
            }
        }
        .frame(
            width: PillLayout.size(for: presentation.phase).width - 6,
            height: PillLayout.size(for: presentation.phase).height - 6
        )
        .background(Color(hex: 0x080808), in: Capsule())
        .background(PillDragArea())
        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.75))
        .contentShape(Capsule())
        .contextMenu {
            Button(presentation.pillAlwaysVisible ? "Hide floating pill" : "Hide pill for this recording") {
                PillManager.shared.hideFromContextMenu()
            }
            Button("Open Omil") { AppContext.appDelegate?.showMainWindow() }
        }
        .padding(3)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .onHover { PillManager.shared.setHovered($0) }
    }

    private var idleContent: some View {
        Button { presentation.start() } label: {
            Label("Start", systemImage: "mic.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        .frame(height: 24)
        }
        .buttonStyle(.plain)
        .help("Start dictation")
        .accessibilityLabel("Start dictation")
    }

    @ViewBuilder
    private var recordingContent: some View {
        HStack(spacing: 6) {
            pillIconButton(icon: "xmark", help: "Cancel recording") {
                presentation.cancel()
            }

            CompactWaveform(levels: presentation.audioLevels)
                .frame(width: 52, height: 24)
                .overlay(PillDragArea())
                .help("Drag to move")

            Button {
                presentation.stop()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 28, height: 28)
                    .background(.white, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Finish recording and transcribe")
            .accessibilityLabel("Finish recording and transcribe")

        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func statusContent(
        icon: String,
        title: String,
        showsProgress: Bool,
        canCancel: Bool,
        canStart: Bool = false
    ) -> some View {
        HStack(spacing: 6) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .frame(width: 14, height: 18)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 14, height: 18)
            }

            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)
                .overlay(PillDragArea())
                .help("Drag to move")

            if canCancel {
                pillIconButton(icon: "xmark", help: "Cancel recording") {
                    presentation.cancel()
                }
            }
            if canStart {
                pillIconButton(icon: "mic.fill", help: "Start new dictation") {
                    presentation.start()
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private func pillIconButton(
        icon: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.72))
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(0.07), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var accessibilityLabel: String {
        switch presentation.phase {
        case .idle: return "Omil is ready to start dictation"
        case .preparing: return "Starting the microphone"
        case .recording: return "Recording"
        case .processing: return presentation.processingStage.title
        case .ready: return presentation.lastCleaned.isEmpty ? "No speech detected" : presentation.statusMessage
        case .failed: return presentation.statusMessage
        }
    }
}

private struct CompactWaveform: View {
    let levels: [Double]

    var body: some View {
        GeometryReader { proxy in
            let visible = Array(levels.suffix(13))
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(Array(visible.enumerated()), id: \.offset) { item in
                    Capsule()
                        .fill(Color.white.opacity(0.96))
                        .frame(maxWidth: .infinity)
                        .frame(height: barHeight(item.element, available: proxy.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }

    private func barHeight(_ level: Double, available: CGFloat) -> CGFloat {
        let normalized = min(1, max(0, level))
        return max(2.5, 2.5 + available * 0.78 * normalized)
    }
}


private struct PillDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> PillDragView { PillDragView() }
    func updateNSView(_ nsView: PillDragView, context: Context) {}
}

private final class PillDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        PillManager.shared.drag(with: event)
    }
}
