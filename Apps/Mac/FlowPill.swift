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
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func debugInfo() -> String {
        guard let p = panel else { return "no panel" }
        return "panel visible=\(p.isVisible)"
    }

    func attach(_ controller: DictationController) {
        if panel != nil { return }
        self.controller = controller
        let view = PillView(controller: controller)
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
        positionBottomCenter(p)
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
        let enabled = controller?.pillEnabled ?? true
        dismissTask?.cancel()
        dismissTask = nil
        resize(p, to: PillLayout.size(for: phase))
        switch phase {
        case .preparing where enabled, .recording where enabled, .processing where enabled:
            if !p.isVisible {
                positionBottomCenter(p)
                p.orderFrontRegardless()
            }
        case .ready where enabled:
            if !p.isVisible {
                positionBottomCenter(p)
                p.orderFrontRegardless()
            }
            dismissTask = Task { [weak self, weak p] in
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
        panel.setFrame(next, display: true, animate: panel.isVisible)
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
    }
}

struct PillView: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        Group {
            switch controller.phase {
            case .recording:
                recordingContent
            case .preparing:
                statusContent(icon: "mic.fill", title: "Starting", showsProgress: true, canDismiss: true)
            case .processing:
                statusContent(
                    icon: controller.processingStage.icon,
                    title: controller.processingStage.title,
                    showsProgress: true,
                    canDismiss: false
                )
            case .ready:
                statusContent(
                    icon: controller.lastCleaned.isEmpty ? "waveform.slash" : "checkmark",
                    title: controller.lastCleaned.isEmpty ? "Nothing heard" : "Done",
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
            width: PillLayout.size(for: controller.phase).width - 6,
            height: PillLayout.size(for: controller.phase).height - 6
        )
        .background(Color(hex: 0x080808), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.75))
        .contentShape(Capsule())
        .padding(3)
        .preferredColorScheme(.dark)
        .animation(.snappy(duration: 0.22), value: controller.phase)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var recordingContent: some View {
        HStack(spacing: 7) {
            pillIconButton(icon: "xmark", help: "Cancel recording") {
                controller.cancel()
            }

            CompactWaveform(levels: controller.audioLevels)
                .frame(width: 70, height: 24)

            Button {
                controller.stop()
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

            if canDismiss {
                Spacer(minLength: 0)
                pillIconButton(icon: "xmark", help: controller.phase == .preparing ? "Cancel" : "Dismiss") {
                    if controller.phase == .preparing {
                        controller.cancel()
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
        switch controller.phase {
        case .idle: return "Omil is ready"
        case .preparing: return "Starting the microphone"
        case .recording: return "Recording"
        case .processing: return controller.processingStage.title
        case .ready: return controller.lastCleaned.isEmpty ? "No speech detected" : controller.statusMessage
        case .failed: return controller.statusMessage
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
