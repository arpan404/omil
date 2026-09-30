import SwiftUI

/// The palettes Omil ships. Each is built from Apple's own neutrals and
/// system colors, tuned by hand in light and dark.
public enum ThemePreset: String, CaseIterable, Identifiable, Sendable {
    case graphite
    case blue
    case titanium

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .graphite: return "Graphite"
        case .blue: return "Blue"
        case .titanium: return "Titanium"
        }
    }

    public var detail: String {
        switch self {
        case .graphite: return "Neutral"
        case .blue: return "System blue"
        case .titanium: return "Warm bronze"
        }
    }

    /// Map saved values from earlier palette sets to the nearest current palette.
    public static func restored(from rawValue: String) -> ThemePreset? {
        if let preset = ThemePreset(rawValue: rawValue) { return preset }
        switch rawValue {
        case "studio", "slate", "lilac", "nocturne", "wisteria": return .graphite
        case "fog", "tide", "moss", "canary", "seaglass", "evergreen": return .blue
        case "linen", "clay", "copperplate", "cardinal": return .titanium
        default: return nil
        }
    }
}
