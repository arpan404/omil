import SwiftUI
import UIKit
import OmilDesign

// MARK: - Theme
//
// The iOS app uses the same palettes as the Mac app (OmilDesign). The chosen
// preset and light/dark preference live in UserDefaults; the resolved colors
// travel through the environment as `\.omil`.

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Automatic"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum ThemeKeys {
    static let preset = "omil.themePreset"
    static let appearance = "omil.appearance"
}

/// Resolved palette colors for the current preset and color scheme.
struct OmilColors {
    let raw: ThemePalette
    let isDark: Bool

    init(_ raw: ThemePalette, isDark: Bool) {
        self.raw = raw
        self.isDark = isDark
    }

    init(preset: ThemePreset, scheme: ColorScheme) {
        self.init(preset.palette(for: scheme), isDark: scheme == .dark)
    }

    var canvas: Color { Color(hex: raw.canvas) }
    var panel: Color { Color(hex: raw.panel) }
    var panelDeep: Color { Color(hex: raw.panelDeep) }
    var panelLifted: Color { Color(hex: raw.panelLifted) }
    var line: Color { Color(hex: raw.line) }
    var lineStrong: Color { Color(hex: raw.lineStrong) }
    var ink: Color { Color(hex: raw.ink) }
    var muted: Color { Color(hex: raw.muted) }
    var faint: Color { Color(hex: raw.faint) }
    var signal: Color { Color(hex: raw.signal) }
    var signalInk: Color { Color(hex: raw.signalInk) }
    var recording: Color { Color(hex: raw.recording) }
    var success: Color { Color(hex: raw.success) }
    var warning: Color { Color(hex: raw.warning) }
}

private struct OmilColorsKey: EnvironmentKey {
    static let defaultValue = OmilColors(preset: .graphite, scheme: .light)
}

extension EnvironmentValues {
    var omil: OmilColors {
        get { self[OmilColorsKey.self] }
        set { self[OmilColorsKey.self] = newValue }
    }
}

/// Resolves the palette from the saved preset and the effective color scheme,
/// and applies it to everything inside (including sheets presented from it).
struct Themed<Content: View>: View {
    @AppStorage(ThemeKeys.preset) private var presetRaw = ThemePreset.graphite.rawValue
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder let content: () -> Content

    var body: some View {
        let colors = OmilColors(preset: ThemePreset.restored(from: presetRaw) ?? .graphite, scheme: scheme)
        content()
            .environment(\.omil, colors)
            .tint(colors.signal)
    }
}

extension View {
    func themed() -> some View { Themed { self } }
}

/// Applies the saved Light/Dark/Automatic choice to every window, so sheets
/// and alerts follow it too, and shares the accent with the keyboard.
struct AppearanceController: ViewModifier {
    @AppStorage(ThemeKeys.appearance) private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage(ThemeKeys.preset) private var presetRaw = ThemePreset.graphite.rawValue

    func body(content: Content) -> some View {
        content
            .onAppear(perform: apply)
            .onChange(of: appearanceRaw) { apply() }
            .onChange(of: presetRaw) { apply() }
    }

    private func apply() {
        let mode = AppearanceMode(rawValue: appearanceRaw) ?? .system
        for scene in UIApplication.shared.connectedScenes {
            guard let scene = scene as? UIWindowScene else { continue }
            for window in scene.windows {
                UIView.transition(with: window, duration: 0.25, options: .transitionCrossDissolve) {
                    window.overrideUserInterfaceStyle = mode.interfaceStyle
                }
            }
        }
        KeyboardAccent.share(ThemePreset.restored(from: presetRaw) ?? .graphite)
    }
}

/// The keyboard extension can't link OmilDesign, so the app hands it the
/// accent colors through the shared app group.
@MainActor
enum KeyboardAccent {
    static func share(_ preset: ThemePreset) {
        guard let defaults = UserDefaults(suiteName: SessionCoordinator.appGroupId) else { return }
        let light = preset.palette(for: .light)
        let dark = preset.palette(for: .dark)
        defaults.set(Int(light.signal), forKey: "omil.keyboard.accent.light")
        defaults.set(Int(light.signalInk), forKey: "omil.keyboard.accentInk.light")
        defaults.set(Int(dark.signal), forKey: "omil.keyboard.accent.dark")
        defaults.set(Int(dark.signalInk), forKey: "omil.keyboard.accentInk.dark")
    }
}

enum Motion {
    static let standard = OmilMotion.standard
    static let quick = OmilMotion.quick
    static let page = Animation.spring(response: 0.45, dampingFraction: 0.9)
}

// MARK: - Buttons

/// Flat buttons: a solid accent fill for the primary action, a quiet neutral
/// fill for secondary ones. No shadows or bevels. Disabled buttons dim but
/// stay readable.
struct OmilButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind = .primary
    /// Overrides the primary fill (e.g. red for a stop action); label turns white.
    var tint: Color? = nil
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        OmilButtonBody(configuration: configuration, kind: kind, tint: tint, fullWidth: fullWidth)
    }
}

private struct OmilButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: OmilButtonStyle.Kind
    let tint: Color?
    let fullWidth: Bool
    @Environment(\.omil) private var colors
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(controlSize == .small ? .subheadline.weight(.semibold) : .body.weight(.semibold))
            .foregroundStyle(foreground)
            .multilineTextAlignment(.center)
            .padding(.horizontal, controlSize == .small ? 14 : 20)
            .padding(.vertical, controlSize == .small ? 8 : 14)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(fill.opacity(pressed ? 0.8 : 1), in: Capsule())
            .contentShape(Capsule())
            .scaleEffect(pressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(Motion.quick, value: pressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return tint == nil ? colors.signalInk : .white
        case .secondary: return colors.ink
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: return tint ?? colors.signal
        case .secondary: return colors.ink.opacity(colors.isDark ? 0.12 : 0.07)
        }
    }
}

/// Gives any control a gentle press-down.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Surfaces

extension View {
    /// Floating surface: Liquid Glass in dark mode on iOS 26; a flat fill with
    /// a hairline edge elsewhere (glass reads as heavy 3D on light content).
    @ViewBuilder
    func floatingSurface<S: InsettableShape>(in shape: S, colors: OmilColors) -> some View {
        if #available(iOS 26, *), colors.isDark {
            glassEffect(.regular, in: shape)
        } else {
            background(shape.fill(colors.panel))
                .overlay(shape.strokeBorder(colors.ink.opacity(colors.isDark ? 0.14 : 0.1), lineWidth: 0.5))
        }
    }

    /// An inset-grouped card, matching the rows in Settings.
    func groupedCard(_ colors: OmilColors) -> some View {
        background(colors.panel, in: RoundedRectangle(cornerRadius: CardMetrics.radius, style: .continuous))
    }
}

enum CardMetrics {
    /// iOS 26 rounds grouped content more than earlier releases.
    static var radius: CGFloat {
        if #available(iOS 26, *) { return 26 }
        return 12
    }
}

/// A System Settings-style colored icon tile.
struct IconTile: View {
    let symbol: String
    let color: Color
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 29

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A large tinted symbol tile for setup pages and empty states.
struct HeroTile: View {
    let symbol: String
    let color: Color
    var foreground: Color = .white
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 84

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension Color {
    /// Apple system colors used for Settings icon tiles.
    static let tileBlue = Color(hex: 0x0A84FF)
    static let tileIndigo = Color(hex: 0x5E5CE6)
    static let tilePurple = Color(hex: 0xBF5AF2)
    static let tileOrange = Color(hex: 0xFF9500)
    static let tileGreen = Color(hex: 0x34C759)
    static let tileTeal = Color(hex: 0x30B0C7)
    static let tileRed = Color(hex: 0xFF3B30)
    static let tileGray = Color(hex: 0x8E8E93)
    static let tilePink = Color(hex: 0xFF2D55)
}
