import SwiftUI

// 1:1 port of android-app/.../ui/theme/Color.kt + the CustomColors
// userBubbleBgColor / agentBubbleBgColor used by ChatPanel.
// Light + Dark palettes mirror the Material 3 scheme exactly.

enum AppColors {
    static let userBubble = Color(light: 0x32628D, dark: 0x2D2060)
    static let agentBubble = Color(light: 0xE9EEF6, dark: 0x1A1A24)
    static let onUserBubble = Color.white
    static let onAgentBubble = Color(light: 0x1F1F1F, dark: 0xEEEEF0)

    static let primary = Color(light: 0x0B57D0, dark: 0x9B8AFB)
    static let onPrimary = Color(light: 0xFFFFFF, dark: 0x1A0E3E)
    static let surface = Color(light: 0xFFFFFF, dark: 0x0E0E14)
    static let onSurface = Color(light: 0x1F1F1F, dark: 0xEEEEF0)
    static let surfaceVariant = Color(light: 0xE1E3E1, dark: 0x2A2A35)
    static let onSurfaceVariant = Color(light: 0x444746, dark: 0x8888A0)
    static let outline = Color(light: 0x747775, dark: 0x3A3A4A)
    static let errorContainer = Color(light: 0xF9DEDC, dark: 0x8C1D18)
    static let onErrorContainer = Color(light: 0x8C1D18, dark: 0xF9DEDC)
}

private extension Color {
    init(light: Int, dark: Int) {
        self = Color(UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(red:   CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue:  CGFloat(hex & 0xFF) / 255,
                           alpha: 1)
        })
    }
}
