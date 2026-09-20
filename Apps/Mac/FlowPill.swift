import AppKit
import Combine
import SwiftUI
import OmilCore

// MARK: - Flow pill (floating dictation control)
//
// Wispr-style: a small floating bubble where you work. Visible while
// recording or finalizing, hidden otherwise. Click Stop/Cancel without
// leaving the current app; the panel never steals focus.

@MainActor
final class PillManager: ObservableObject {
    static let shared = PillManager()

    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private weak var controller: DictationController?

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
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 92)
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 92),
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
            y: frame.minY + 32))
    }

    private func reflect(phase: DictationController.Phase) {
        guard let p = panel else { return }
        let enabled = controller?.pillEnabled ?? true
        switch phase {
        case .recording, .processing where enabled:
            if !p.isVisible {
                positionBottomCenter(p)
                p.orderFrontRegardless()
            }
        default:
            if p.isVisible { p.orderOut(nil) }
        }
    }
}

struct PillView: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(controller.phase == .recording ? Color.red : Color.orange)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.phase == .recording ? "Recording…" : "Finalizing…")
                    .font(.headline)
                Text(controller.phase == .recording && !controller.draftText.isEmpty
                     ? controller.draftText : controller.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            Spacer()
            if controller.phase == .recording {
                Button("Stop") { controller.stop() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
                Button("Cancel") { controller.cancel() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(10)
        .frame(width: 400)
        .background(.thickMaterial)
        .cornerRadius(14)
        .padding(6)
    }
}
