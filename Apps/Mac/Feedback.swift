import AppKit
import SwiftUI
import OmilDesign

// MARK: - Action feedback
//
// Every action answers the user: icon buttons react to hover and press, and
// completed actions confirm themselves in a small glass banner at the bottom of
// the window, with Undo where the action can be reversed. Banners are also
// announced to VoiceOver.

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let symbol: String
        let undo: (() -> Void)?

        static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
    }

    @Published private(set) var current: Toast?
    private var dismissTask: Task<Void, Never>?

    func show(_ message: String, symbol: String = "checkmark.circle.fill", undo: (() -> Void)? = nil) {
        let toast = Toast(message: message, symbol: symbol, undo: undo)
        withAnimation(OmilMotion.standard) { current = toast }
        AccessibilityNotification.Announcement(message).post()
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(undo == nil ? 2.2 : 4.5))
            guard !Task.isCancelled else { return }
            self?.dismiss(toast)
        }
    }

    func dismiss(_ toast: Toast? = nil) {
        guard toast == nil || toast == current else { return }
        withAnimation(OmilMotion.standard) { current = nil }
    }

    func performUndo() {
        guard let undo = current?.undo else { return }
        undo()
        dismiss()
    }

    /// Copies text and confirms it.
    func copy(_ text: String, message: String = "Copied to Clipboard") {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show(message, symbol: "doc.on.doc.fill")
    }
}

private struct ToastBanner: View {
    let toast: ToastCenter.Toast
    @ObservedObject var center: ToastCenter

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(OmilTheme.signal)
                .font(.system(size: 14, weight: .semibold))
            Text(toast.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OmilTheme.ink)
            if toast.undo != nil {
                Divider().frame(height: 16)
                Button("Undo") { center.performUndo() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OmilTheme.signal)
                    .keyboardShortcut("z", modifiers: .command)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .liquidGlass(in: Capsule())
        .onTapGesture { center.dismiss(toast) }
    }
}

extension View {
    /// Hosts action banners at the bottom of a window.
    func toastHost(bottomPadding: CGFloat = 20) -> some View {
        modifier(ToastHost(bottomPadding: bottomPadding))
    }
}

private struct ToastHost: ViewModifier {
    let bottomPadding: CGFloat
    @ObservedObject private var center = ToastCenter.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = center.current {
                ToastBanner(toast: toast, center: center)
                    .padding(.bottom, bottomPadding)
                    .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.96)))
                    .id(toast.id)
            }
        }
    }
}

/// Icon-only button: a soft circle appears on hover, the icon dips on press,
/// and destructive actions turn red before you click.
struct IconButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, destructive: destructive)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let destructive: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(foreground)
            .frame(width: 28, height: 28)
            .background {
                Circle().fill(background)
            }
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(isEnabled ? 1 : 0.35)
            .onHover { hovered = isEnabled && $0 }
            .animation(OmilMotion.quick, value: hovered)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }

    private var foreground: Color {
        guard isEnabled else { return OmilTheme.muted }
        if destructive && hovered { return OmilTheme.coral }
        return hovered ? OmilTheme.ink : OmilTheme.muted
    }

    private var background: Color {
        guard hovered else { return .clear }
        return destructive ? OmilTheme.coral.opacity(0.12) : OmilTheme.ink.opacity(0.08)
    }
}
