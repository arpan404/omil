import SwiftUI

/// Raw palette values, stored as hex so AppKit and UIKit can build native colors too.
public struct ThemePalette: Sendable, Equatable {
    public let canvas: UInt
    public let sidebar: UInt
    public let panel: UInt
    public let panelDeep: UInt
    public let panelLifted: UInt
    public let line: UInt
    public let lineStrong: UInt
    public let ink: UInt
    public let muted: UInt
    public let faint: UInt
    public let signal: UInt
    public let signalInk: UInt
    public let recording: UInt
    public let success: UInt
    public let warning: UInt
}

extension ThemePreset {
    public func palette(for scheme: ColorScheme) -> ThemePalette {
        let dark = scheme == .dark
        // Apple system status colors; the light variants use the accessible
        // (higher-contrast) shades so they stay readable as text.
        let recording: UInt = dark ? 0xFF453A : 0xFF3B30
        let success: UInt = dark ? 0x30D158 : 0x248A3D
        let warning: UInt = dark ? 0xFF9F0A : 0xC93400
        switch (self, dark) {
        case (.graphite, false):
            return ThemePalette(canvas: 0xF5F5F7, sidebar: 0xF0F0F2, panel: 0xFFFFFF,
                                panelDeep: 0xF2F2F4, panelLifted: 0xE8E8ED, line: 0xE5E5EA,
                                lineStrong: 0xD1D1D6, ink: 0x1D1D1F, muted: 0x6E6E73,
                                faint: 0x86868B, signal: 0x1D1D1F, signalInk: 0xFFFFFF,
                                recording: recording, success: success, warning: warning)
        case (.graphite, true):
            return ThemePalette(canvas: 0x161617, sidebar: 0x1C1C1E, panel: 0x1C1C1E,
                                panelDeep: 0x18181A, panelLifted: 0x2C2C2E, line: 0x2C2C2E,
                                lineStrong: 0x3A3A3C, ink: 0xF5F5F7, muted: 0xA1A1A6,
                                faint: 0x8E8E93, signal: 0xF5F5F7, signalInk: 0x1D1D1F,
                                recording: recording, success: success, warning: warning)
        case (.blue, false):
            return ThemePalette(canvas: 0xF5F5F7, sidebar: 0xF0F0F2, panel: 0xFFFFFF,
                                panelDeep: 0xF2F2F4, panelLifted: 0xE8E8ED, line: 0xE5E5EA,
                                lineStrong: 0xD1D1D6, ink: 0x1D1D1F, muted: 0x6E6E73,
                                faint: 0x86868B, signal: 0x0071E3, signalInk: 0xFFFFFF,
                                recording: recording, success: success, warning: warning)
        case (.blue, true):
            return ThemePalette(canvas: 0x151618, sidebar: 0x1B1C1F, panel: 0x1C1D20,
                                panelDeep: 0x18191B, panelLifted: 0x2B2D31, line: 0x2B2D31,
                                lineStrong: 0x3A3C41, ink: 0xF5F5F7, muted: 0xA1A1A6,
                                faint: 0x8E8E93, signal: 0x0A84FF, signalInk: 0xFFFFFF,
                                recording: recording, success: success, warning: warning)
        case (.titanium, false):
            return ThemePalette(canvas: 0xF5F3EF, sidebar: 0xEFECE7, panel: 0xFFFEFC,
                                panelDeep: 0xF1EEE9, panelLifted: 0xE7E2DA, line: 0xE4DFD7,
                                lineStrong: 0xCFC7BB, ink: 0x26231F, muted: 0x6F675E,
                                faint: 0x857C71, signal: 0x8C6D4F, signalInk: 0xFFFFFF,
                                recording: recording, success: success, warning: warning)
        case (.titanium, true):
            return ThemePalette(canvas: 0x1A1917, sidebar: 0x201E1C, panel: 0x23211E,
                                panelDeep: 0x1E1C1A, panelLifted: 0x2F2C28, line: 0x332F2B,
                                lineStrong: 0x4A443D, ink: 0xF4F1EC, muted: 0xB3AA9E,
                                faint: 0x9A9185, signal: 0xC9AE8B, signalInk: 0x221A11,
                                recording: recording, success: success, warning: warning)
        }
    }
}

extension Color {
    public init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
