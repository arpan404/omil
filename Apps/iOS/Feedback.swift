import SwiftUI
import UIKit

// MARK: - Action feedback
//
// Completed actions confirm themselves in a small capsule banner at the bottom
// of the screen (with Undo where the action can be reversed), play a matching
// haptic, and are announced to VoiceOver. Every screen and sheet hosts the
// banner; the haptic plays once, from the center.

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    enum Tone { case success, warning, error }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let symbol: String
        let tone: Tone
        let undo: (() -> Void)?

        static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
    }

    @Published private(set) var current: Toast?
    private var dismissTask: Task<Void, Never>?
    private let haptics = UINotificationFeedbackGenerator()

    func show(_ message: String, symbol: String = "checkmark.circle.fill",
              tone: Tone = .success, undo: (() -> Void)? = nil) {
        let toast = Toast(message: message, symbol: symbol, tone: tone, undo: undo)
        withAnimation(Motion.standard) { current = toast }
        haptics.notificationOccurred(tone == .success ? .success : tone == .warning ? .warning : .error)
        UIAccessibility.post(notification: .announcement, argument: message)
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(undo == nil ? 2 : 4.5))
            guard !Task.isCancelled else { return }
            self?.dismiss(toast)
        }
    }

    func dismiss(_ toast: Toast? = nil) {
        guard toast == nil || toast == current else { return }
        withAnimation(Motion.standard) { current = nil }
    }

    func performUndo() {
        guard let undo = current?.undo else { return }
        undo()
        dismiss()
    }

    func copy(_ text: String) {
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        show("Copied", symbol: "doc.on.doc.fill")
    }
}

private struct ToastBanner: View {
    let toast: ToastCenter.Toast
    @ObservedObject var center: ToastCenter
    @Environment(\.omil) private var colors

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .font(.subheadline.weight(.semibold))
            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(colors.ink)
            if toast.undo != nil {
                Divider().frame(height: 16)
                Button("Undo") { center.performUndo() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(colors.signal)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .floatingSurface(in: Capsule(), colors: colors)
        .onTapGesture { center.dismiss(toast) }
        .accessibilityElement(children: .contain)
    }

    private var tint: Color {
        switch toast.tone {
        case .success: return colors.signal
        case .warning: return colors.warning
        case .error: return colors.recording
        }
    }
}

extension View {
    /// Hosts action banners at the bottom of a screen or sheet.
    func toastHost() -> some View { modifier(ToastHost()) }
}

private struct ToastHost: ViewModifier {
    @ObservedObject private var center = ToastCenter.shared

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast = center.current {
                    ToastBanner(toast: toast, center: center)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.94)))
                        .id(toast.id)
                }
            }
    }
}
