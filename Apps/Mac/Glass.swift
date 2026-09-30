import AppKit
import SwiftUI
import OmilDesign

// MARK: - Window material and floating controls
//
// Windows draw a behind-window blur tinted with the palette canvas; the user
// controls how much shows through. Floating controls use Liquid Glass in dark
// mode on macOS 26 and a flat fill everywhere else.

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// The window backdrop: frosted desktop under a palette tint.
struct GlassBackdrop: View {
    @ObservedObject private var appearance = AppAppearance.shared

    private var dark: Bool { appearance.colorScheme == .dark }

    var body: some View {
        let palette = appearance.palette
        let t = min(1, max(0, appearance.windowTransparency))
        ZStack {
            VisualEffectBackground(material: dark ? .hudWindow : .underWindowBackground)
                .opacity(blurOpacity(t))
            Color(hex: palette.canvas).opacity(tintOpacity(t))
        }
        .accessibilityHidden(true)
    }

    /// The palette tint thins out across the first 85% of the slider.
    private func tintOpacity(_ t: Double) -> Double {
        max(0, 1 - t / 0.85)
    }

    /// The frosted blur stays until the last 15%, then fades to fully clear.
    private func blurOpacity(_ t: Double) -> Double {
        t <= 0.85 ? 1 : max(0, 1 - (t - 0.85) / 0.15)
    }
}

enum GlassLook {
    @MainActor static var isDark: Bool { AppAppearance.shared.colorScheme == .dark }
}

extension View {
    /// Floating-control surface. Dark mode on macOS 26 gets real Liquid Glass;
    /// light mode is flat — solid fill, hairline edge, no shadow — because glass
    /// shadows read as heavy 3D on light backgrounds.
    @ViewBuilder
    func liquidGlass<S: InsettableShape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        fallbackFill: Color? = nil
    ) -> some View {
        if #available(macOS 26.0, *), GlassLook.isDark {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background {
                shape.fill(tint ?? fallbackFill ?? (GlassLook.isDark ? Color.white.opacity(0.08) : Color.white.opacity(0.92)))
            }
            .overlay(shape.strokeBorder(OmilTheme.ink.opacity(GlassLook.isDark ? 0.12 : 0.1), lineWidth: 0.5))
        }
    }

}

extension View {
    /// Apple's own button styles: Liquid Glass on macOS 26, bordered before it.
    /// Flat buttons in both appearances: no shadow, no bevel, no glass.
    func omilButton(prominent: Bool = false, tint: Color? = nil) -> some View {
        buttonStyle(FlatButtonStyle(prominent: prominent, tint: tint))
    }
}

struct FlatButtonStyle: ButtonStyle {
    var prominent = false
    /// Overrides the accent for prominent buttons (e.g. red while recording).
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        FlatButtonBody(configuration: configuration, prominent: prominent, tint: tint)
    }
}

private struct FlatButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let tint: Color?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var hovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: prominent ? .semibold : .medium))
            .lineLimit(1)
            .foregroundStyle(prominent ? (tint == nil ? OmilTheme.signalInk : .white) : OmilTheme.ink)
            .padding(.horizontal, controlSize == .large ? 18 : 12)
            .frame(minHeight: controlSize == .large ? 34 : 26)
            .background(fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovered = isEnabled && $0 }
            .animation(OmilMotion.quick, value: hovered)
            .animation(OmilMotion.quick, value: configuration.isPressed)
            .animation(OmilMotion.standard, value: tint)
    }

    private var fill: Color {
        let pressed = configuration.isPressed
        if prominent {
            return (tint ?? OmilTheme.signal).opacity(pressed ? 0.78 : hovered ? 0.9 : 1)
        }
        let base = GlassLook.isDark ? 0.1 : 0.06
        return OmilTheme.ink.opacity(pressed ? base + 0.08 : hovered ? base + 0.04 : base)
    }
}

/// Sidebar row with a theme-aware selection instead of the system accent,
/// so the sidebar follows the palette like the rest of the window.
struct ThemedSidebarRow<Icon: View>: View {
    let title: String
    let selected: Bool
    var namespace: Namespace.ID? = nil
    @ViewBuilder let icon: () -> Icon
    let action: () -> Void
    @State private var hovered = false

    init(title: String, selected: Bool, namespace: Namespace.ID? = nil,
         @ViewBuilder icon: @escaping () -> Icon, action: @escaping () -> Void) {
        self.title = title
        self.selected = selected
        self.namespace = namespace
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon()
                    .frame(width: 22)
                Text(title)
                    .foregroundStyle(OmilTheme.ink)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: selected ? .medium : .regular))
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background {
                ZStack {
                    if hovered && !selected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(OmilTheme.ink.opacity(0.05))
                    }
                    if selected {
                        // One highlight that slides between rows.
                        if let namespace {
                            highlight.matchedGeometryEffect(id: "sidebar-selection", in: namespace)
                        } else {
                            highlight
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var highlight: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(OmilTheme.signal.opacity(GlassLook.isDark ? 0.22 : 0.12))
    }
}
