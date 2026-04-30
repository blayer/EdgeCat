import XCTest
import SwiftUI
@testable import EdgeCat

@MainActor
final class EdgeCatThemeTests: XCTestCase {

    func testDefaultThemeMirrorsAppColors() {
        let t = EdgeCatTheme()
        XCTAssertEqual(t.colors.surface.description, AppColors.surface.description)
        XCTAssertEqual(t.colors.primary.description, AppColors.primary.description)
        XCTAssertEqual(t.colors.userBubble.description, AppColors.userBubble.description)
        XCTAssertEqual(t.colors.errorContainer.description, AppColors.errorContainer.description)
    }

    func testSpacingDefaults() {
        let t = EdgeCatTheme()
        XCTAssertEqual(t.spacing.unit, 4)
        XCTAssertEqual(t.spacing.bubbleCornerRadius, 18)
        XCTAssertEqual(t.spacing.avatarSize, 32)
    }

    func testRuntimeColorOverrideWorks() {
        var custom = ThemeColors.default
        custom.surface = Color.purple
        let t = EdgeCatTheme(colors: custom)
        XCTAssertEqual(t.colors.surface.description, Color.purple.description)
        // Other fields stay on the default chain.
        XCTAssertEqual(t.colors.primary.description, AppColors.primary.description)
    }

    func testSharedSingletonStable() {
        let a = EdgeCatTheme.shared
        let b = EdgeCatTheme.shared
        XCTAssertTrue(a === b, "shared should be a single instance")
    }
}
