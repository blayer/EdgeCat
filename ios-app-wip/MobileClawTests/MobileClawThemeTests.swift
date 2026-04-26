import XCTest
import SwiftUI
@testable import MobileClaw

@MainActor
final class MobileClawThemeTests: XCTestCase {

    func testDefaultThemeMirrorsAppColors() {
        let t = MobileClawTheme()
        XCTAssertEqual(t.colors.surface.description, AppColors.surface.description)
        XCTAssertEqual(t.colors.primary.description, AppColors.primary.description)
        XCTAssertEqual(t.colors.userBubble.description, AppColors.userBubble.description)
        XCTAssertEqual(t.colors.errorContainer.description, AppColors.errorContainer.description)
    }

    func testSpacingDefaults() {
        let t = MobileClawTheme()
        XCTAssertEqual(t.spacing.unit, 4)
        XCTAssertEqual(t.spacing.bubbleCornerRadius, 18)
        XCTAssertEqual(t.spacing.avatarSize, 32)
    }

    func testRuntimeColorOverrideWorks() {
        var custom = ThemeColors.default
        custom.surface = Color.purple
        let t = MobileClawTheme(colors: custom)
        XCTAssertEqual(t.colors.surface.description, Color.purple.description)
        // Other fields stay on the default chain.
        XCTAssertEqual(t.colors.primary.description, AppColors.primary.description)
    }

    func testSharedSingletonStable() {
        let a = MobileClawTheme.shared
        let b = MobileClawTheme.shared
        XCTAssertTrue(a === b, "shared should be a single instance")
    }
}
