import SwiftUI

/// Spacing on a 4pt grid.
public enum OmilSpace {
    public static let lg: CGFloat = 24
    public static let xl: CGFloat = 32
}

public enum OmilRadius {
    public static let control: CGFloat = 8
}

/// The type scale. On iOS each step follows Dynamic Type; on macOS the sizes
/// match the platform's fixed text metrics.
public enum OmilFont {
    #if os(macOS)
    public static let caption = Font.system(size: 11)
    public static let callout = Font.system(size: 12)
    public static let body = Font.system(size: 13)
    public static let reading = Font.system(size: 15)
    /// Display type: SF Pro Display at large sizes, as in Apple's own apps.
    public static let display = Font.system(size: 28, weight: .bold)
    public static let displaySmall = Font.system(size: 22, weight: .semibold)
    public static let mono = Font.system(size: 12, design: .monospaced)
    #else
    public static let caption = Font.caption
    public static let callout = Font.subheadline
    public static let body = Font.body
    public static let reading = Font.body
    public static let display = Font.largeTitle.weight(.bold)
    public static let displaySmall = Font.title2.weight(.semibold)
    public static let mono = Font.footnote.monospaced()
    #endif

    /// Snaps an arbitrary size onto the type scale.
    public static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: snapped(size), weight: weight)
    }

    static func snapped(_ size: CGFloat) -> CGFloat {
        let scale: [CGFloat] = [11, 12, 13, 15, 17, 20, 26, 34]
        return scale.min(by: { abs($0 - size) < abs($1 - size) }) ?? size
    }
}

extension View {
    /// Display type with Apple's tight optical tracking.
    public func omilDisplay(small: Bool = false) -> some View {
        font(small ? OmilFont.displaySmall : OmilFont.display).tracking(small ? -0.3 : -0.5)
    }
}

public enum OmilMotion {
    public static let quick = Animation.easeOut(duration: 0.16)
    public static let standard = Animation.spring(response: 0.32, dampingFraction: 0.86)
}
