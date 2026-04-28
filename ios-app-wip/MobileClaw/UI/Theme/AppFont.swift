import SwiftUI

// Nunito body typography — same family Android bundles in
// android-app/.../res/font/. Pre-baked role-named variants so call sites
// don't have to remember PostScript names.

enum AppFont {
    static func nunito(_ weight: Weight = .regular, size: CGFloat) -> Font {
        Font.custom(weight.psName, size: size)
    }

    enum Weight {
        case extraLight, light, regular, medium, semibold, bold, extraBold, black

        var psName: String {
            switch self {
            case .extraLight: return "Nunito-ExtraLight"
            case .light:      return "Nunito-Light"
            case .regular:    return "Nunito-Regular"
            case .medium:     return "Nunito-Medium"
            case .semibold:   return "Nunito-SemiBold"
            case .bold:       return "Nunito-Bold"
            case .extraBold:  return "Nunito-ExtraBold"
            case .black:      return "Nunito-Black"
            }
        }
    }
}

/// Convenience role-styles. Mirrors Android's Material 3 type roles
/// (`titleLarge`, `bodyMedium`, etc.) but maps onto Nunito sizes that look
/// natural on iOS dynamic-type defaults.
extension Font {
    static var titleLargeNunito: Font   { AppFont.nunito(.bold, size: 24) }
    static var titleMediumNunito: Font  { AppFont.nunito(.semibold, size: 18) }
    static var titleSmallNunito: Font   { AppFont.nunito(.semibold, size: 16) }
    static var bodyLargeNunito: Font    { AppFont.nunito(.regular, size: 17) }
    static var bodyMediumNunito: Font   { AppFont.nunito(.regular, size: 16) }
    static var bodySmallNunito: Font    { AppFont.nunito(.regular, size: 14) }
    static var labelLargeNunito: Font   { AppFont.nunito(.semibold, size: 16) }
    static var labelMediumNunito: Font  { AppFont.nunito(.medium, size: 14) }
    static var labelSmallNunito: Font   { AppFont.nunito(.medium, size: 13) }
}
