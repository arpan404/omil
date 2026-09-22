import AppKit
import Combine
import SwiftUI
import OmilCore

// MARK: - Floating dictation control

private enum PillLayout {
    static func size(for phase: DictationController.Phase) -> NSSize {
        switch phase {
        case .idle: return NSSize(width: 92, height: 36)
        case .preparing: return NSSize(width: 132, height: 40)
        case .recording: return NSSize(width: 160, height: 44)
        case .processing: return NSSize(width: 158, height: 40)
        case .ready: return NSSize(width: 132, height: 38)
        case .failed: return NSSize(width: 196, height: 42)
        }
    }
}

@MainActor
final class PillManager: ObservableObject {
    static let shared = PillManager()

    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private weak var controller: DictationController?
    private var presentation: PillPresentation?
    private var dismissTask: Task<Void, Never>?

    private init() {}

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
        if let saved = UserDefaults.standard.string(forKey: "omil.pillPosition") {
            p.setFrameOrigin(NSPointFromString(saved))
            keepOnScreen(p)
        } else {
            positionBottomCenter(p)
        }
        p.alphaValue = 0.72
        self.panel = p
        controller.$phase.sink { [weak self] phase in
            self?.reflect(phase: phase)
        }.store(in: &cancellables)
        controller.$pillEnabled.sink { [weak self] _ in
            guard let self, let c = self.controller else { return }
            self.reflect(phase: c.phase)
        }.store(in: &cancellables)
    }

    private func positionBottomCenter(_ p: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        p.setFrameOrigin(NSPoint(
            x: frame.midX - p.frame.width / 2,
            y: frame.minY + 24))
    }

    private func reflect(phase: DictationController.Phase) {
        guard let p = panel else { return }
        let enabled = Self.isEligible(source: controller?.recordingSource ?? .app, enabled: controller?.pillEnabled ?? true)
        dismissTask?.cancel()
        dismissTask = nil
        resize(p, to: PillLayout.size(for: phase))
        switch phase {
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
            dismissTask = Task { @MainActor [weak self, weak p] in
                try? await Task.sleep(for: .seconds(1.4))
                guard !Task.isCancelled,
                      self?.controller?.phase == .ready else { return }
                p?.orderOut(nil)
            }
        case .failed where enabled:
            if p.isVisible { p.orderFrontRegardless() }
        default:
            if p.isVisible { p.orderOut(nil) }
        }
    }

    private func resize(_ panel: NSPanel, to size: NSSize) {
        guard panel.frame.size != size else { return }
        let current = panel.frame
        let next = NSRect(
            x: current.midX - size.width / 2,
            y: current.minY,
            width: size.width,
            height: size.height
        )
        panel.setFrame(next, display: true)
        keepOnScreen(panel)
    }

    static func isEligible(source: DictationController.RecordingSource, enabled: Bool) -> Bool {
        enabled && (source == .shortcut || source == .menuBar)
    }

    func setHovered(_ hovered: Bool) {
        panel?.alphaValue = hovered ? 1 : 0.72
    }

    func drag(with event: NSEvent) {
        guard let panel else { return }
        panel.performDrag(with: event)
        keepOnScreen(panel)
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: "omil.pillPosition")
    }

    private func keepOnScreen(_ panel: NSPanel) {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(panel.frame) }) else {
            positionBottomCenter(panel)
            return
        }
        let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        panel.setFrameOrigin(NSPoint(
            x: min(max(panel.frame.minX, bounds.minX), bounds.maxX - panel.frame.width),
            y: min(max(panel.frame.minY, bounds.minY), bounds.maxY - panel.frame.height)
        ))
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
    }
}

@MainActor
final class PillPresentation: ObservableObject {
    @Published private(set) var phase: DictationController.Phase
    @Published private(set) var processingStage: DictationController.ProcessingStage
    @Published private(set) var lastCleaned: String
    @Published private(set) var statusMessage: String
    @Published private(set) var audioLevels: [Double]

    private weak var controller: DictationController?
    private var cancellables = Set<AnyCancellable>()

    init(controller: DictationController) {
        self.controller = controller
        phase = controller.phase
        processingStage = controller.processingStage
        lastCleaned = controller.lastCleaned
        statusMessage = controller.statusMessage
        audioLevels = controller.audioLevels

        controller.$phase.sink { [weak self] in self?.phase = $0 }.store(in: &cancellables)
        controller.$processingStage.sink { [weak self] in self?.processingStage = $0 }.store(in: &cancellables)
        controller.$lastCleaned.sink { [weak self] in self?.lastCleaned = $0 }.store(in: &cancellables)
        controller.$statusMessage.sink { [weak self] in self?.statusMessage = $0 }.store(in: &cancellables)
        controller.$audioLevels.sink { [weak self] in self?.audioLevels = $0 }.store(in: &cancellables)
    }

    func cancel() { controller?.cancel() }
    func stop() { controller?.stop() }
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
                statusContent(icon: "mic.fill", title: "Starting", showsProgress: true, canDismiss: true)
            case .processing:
                statusContent(
                    icon: presentation.processingStage.icon,
                    title: presentation.processingStage.title,
                    showsProgress: true,
                    canDismiss: false
                )
            case .ready:
                statusContent(
                    icon: presentation.lastCleaned.isEmpty ? "waveform.slash" : "checkmark",
                    title: presentation.lastCleaned.isEmpty ? "Nothing heard" : "Done",
                    showsProgress: false,
                    canDismiss: false
                )
            case .failed:
                statusContent(icon: "exclamationmark", title: "Could not finish", showsProgress: false, canDismiss: true)
            case .idle:
                CompactWaveform(levels: Array(repeating: 0.18, count: 13))
                    .frame(width: 66, height: 18)
            }
        }
        .frame(
            width: PillLayout.size(for: presentation.phase).width - 6,
            height: PillLayout.size(for: presentation.phase).height - 6
        )
        .background(Color(hex: 0x080808), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.75))
        .contentShape(Capsule())
        .padding(3)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .onHover { PillManager.shared.setHovered($0) }
    }

    @ViewBuilder
    private var recordingContent: some View {
        HStack(spacing: 7) {
            pillIconButton(icon: "xmark", help: "Cancel recording") {
                presentation.cancel()
            }

            CompactWaveform(levels: presentation.audioLevels)
                .frame(width: 70, height: 24)
                .overlay(PillDragArea())
                .help("Drag to move")

            Button {
                presentation.stop()
            } label: {
                ZStack {
                    Circle().fill(Color.white)
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Color.black)
                        .frame(width: 9, height: 9)
                }
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Stop and transcribe")
            .accessibilityLabel("Stop and transcribe")
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func statusContent(
        icon: String,
        title: String,
        showsProgress: Bool,
        canDismiss: Bool
    ) -> some View {
        HStack(spacing: 8) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
            }

            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .overlay(PillDragArea())
                .help("Drag to move")

            if canDismiss {
                Spacer(minLength: 0)
                pillIconButton(icon: "xmark", help: presentation.phase == .preparing ? "Cancel" : "Dismiss") {
                    if presentation.phase == .preparing {
                        presentation.cancel()
                    } else {
                        PillManager.shared.dismiss()
                    }
                }
            }
        }
        .padding(.horizontal, 10)
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
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.07), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var accessibilityLabel: String {
        switch presentation.phase {
        case .idle: return "Omil is ready"
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
