import SwiftUI

// 1:1 port of android-app/.../ui/theme/MobileClawTheme.kt — a centralized
// theme surface so colors / typography / spacing have one source of truth
// and can be runtime-swapped without touching individual views.
//
// AppColors stays the underlying value source; MobileClawTheme.colors
// delegates to it so existing call sites (AppColors.surface, etc.) keep
// working. New code should prefer @Environment(\.theme) so a future custom
// theme can override without a global mutation.

public struct ThemeColors: Sendable {
    public var primary: Color
    public var onPrimary: Color
    public var surface: Color
    public var onSurface: Color
    public var surfaceVariant: Color
    public var onSurfaceVariant: Color
    public var outline: Color
    public var userBubble: Color
    public var onUserBubble: Color
    public var agentBubble: Color
    public var onAgentBubble: Color
    public var errorContainer: Color
    public var onErrorContainer: Color

    public static let `default` = ThemeColors(
        primary: AppColors.primary,
        onPrimary: AppColors.onPrimary,
        surface: AppColors.surface,
        onSurface: AppColors.onSurface,
        surfaceVariant: AppColors.surfaceVariant,
        onSurfaceVariant: AppColors.onSurfaceVariant,
        outline: AppColors.outline,
        userBubble: AppColors.userBubble,
        onUserBubble: AppColors.onUserBubble,
        agentBubble: AppColors.agentBubble,
        onAgentBubble: AppColors.onAgentBubble,
        errorContainer: AppColors.errorContainer,
        onErrorContainer: AppColors.onErrorContainer
    )
}

public struct ThemeSpacing: Sendable {
    public var unit: CGFloat = 4
    public var bubbleCornerRadius: CGFloat = 18
    public var avatarSize: CGFloat = 32
    public static let `default` = ThemeSpacing()
}

@Observable
public final class MobileClawTheme: @unchecked Sendable {
    public var colors: ThemeColors
    public var spacing: ThemeSpacing

    public init(colors: ThemeColors = .default, spacing: ThemeSpacing = .default) {
        self.colors = colors
        self.spacing = spacing
    }

    public static let shared = MobileClawTheme()
}

private struct MobileClawThemeKey: EnvironmentKey {
    static let defaultValue: MobileClawTheme = .shared
}

public extension EnvironmentValues {
    var theme: MobileClawTheme {
        get { self[MobileClawThemeKey.self] }
        set { self[MobileClawThemeKey.self] = newValue }
    }
}
