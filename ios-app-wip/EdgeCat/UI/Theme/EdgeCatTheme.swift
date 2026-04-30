import SwiftUI

// 1:1 port of android-app/.../ui/theme/EdgeCatTheme.kt — a centralized
// theme surface so colors / typography / spacing have one source of truth
// and can be runtime-swapped without touching individual views.
//
// AppColors stays the underlying value source; EdgeCatTheme.colors
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
public final class EdgeCatTheme: @unchecked Sendable {
    public var colors: ThemeColors
    public var spacing: ThemeSpacing

    public init(colors: ThemeColors = .default, spacing: ThemeSpacing = .default) {
        self.colors = colors
        self.spacing = spacing
    }

    public static let shared = EdgeCatTheme()
}

private struct EdgeCatThemeKey: EnvironmentKey {
    static let defaultValue: EdgeCatTheme = .shared
}

public extension EnvironmentValues {
    var theme: EdgeCatTheme {
        get { self[EdgeCatThemeKey.self] }
        set { self[EdgeCatThemeKey.self] = newValue }
    }
}
