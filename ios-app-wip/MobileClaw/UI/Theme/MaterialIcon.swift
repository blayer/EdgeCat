import SwiftUI

// 1:1 icon parity with Android. Compose's `Icons.Rounded.*` ImageVector
// catalog renders the same Material Symbols Rounded glyph set Google
// publishes at fonts.google.com/icons. The font supports ligatures, so a
// `Text("rocket_launch")` rendered in MaterialSymbolsRounded becomes the
// rocket glyph — same name Compose uses internally (`Icons.Rounded.RocketLaunch`).
//
// Use the `MIcon` shorthand in views; pass the snake_case name from
// fonts.google.com/icons for whichever icon you'd reach for on Android.

struct MIcon: View {
    let name: String
    var size: CGFloat = 20
    var weight: Weight = .regular
    var fill: Bool = false

    enum Weight: Int, Sendable {
        case thin = 100
        case light = 300
        case regular = 400
        case medium = 500
        case semibold = 600
        case bold = 700

        var fontWeight: Font.Weight {
            switch self {
            case .thin: return .thin
            case .light: return .light
            case .regular: return .regular
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            }
        }
    }

    var body: some View {
        // The variable axes (FILL, GRAD, opsz, wght) can't be tuned from
        // SwiftUI's font API directly — Apple's Core Text doesn't expose
        // OpenType variation tables on `Font.custom`. We approximate by
        // selecting the regular cut and letting `fontWeight` push line
        // weight via Apple's variable-font fallback (works on iOS 17+).
        Text(name)
            .font(.custom("MaterialSymbolsRounded-Regular", size: size))
            .fontWeight(weight.fontWeight)
            // Disable ligature-prevention; Material Symbols uses ligatures
            // to map glyph names to codepoints.
            .tracking(0)
    }
}

/// Curated namespace for the icons we actually use, so callers don't have
/// to remember the snake_case names. Each constant is the same name
/// fonts.google.com/icons displays — also matches Compose's
/// `Icons.Rounded.<PascalCase>` (`rocket_launch` ↔ `Icons.Rounded.RocketLaunch`).
enum MIconName {
    static let arrowBack          = "arrow_back"
    static let add                = "add"
    static let close              = "close"
    static let cancel             = "cancel"
    static let rocketLaunch       = "rocket_launch"
    static let tune               = "tune"
    static let autoAwesome        = "auto_awesome"
    static let chatBubbleOutline  = "chat_bubble_outline"
    static let pushPin            = "push_pin"
    static let delete             = "delete"
    static let search             = "search"
    static let expandMore         = "expand_more"
    static let expandLess         = "expand_less"
    static let visibility         = "visibility"
    static let key                = "key"
    static let extension_         = "extension"
    static let openInNew          = "open_in_new"
    static let contentPaste       = "content_paste"
    static let arrowDropDown      = "arrow_drop_down"
    static let send               = "send"
    static let mic                = "mic"
    static let photoCamera        = "photo_camera"
    static let photoLibrary       = "photo_library"
    static let image              = "image"
    static let settings           = "settings"
    static let chevronRight       = "chevron_right"
    static let chevronLeft        = "chevron_left"
    static let stop               = "stop"
    static let lightbulb          = "lightbulb"
    static let graphicEq          = "graphic_eq"
    static let refresh            = "refresh"
    static let contentCopy        = "content_copy"
    static let check              = "check"
}
