import XCTest
@testable import MobileClaw

/// End-to-end-ish scenarios that exercise the data layer behind the
/// Settings + Skill manager UI changes. Each test acts like a user
/// completing a flow and verifies that the persisted state lines up.
final class SettingsScenarioTests: XCTestCase {

    // Track per-scenario UserDefaults keys to clean up between runs so the
    // shared `UserDefaults.standard` doesn't leak across tests.
    private let touchedKeys: [String] = [
        SamplerSettings.acceleratorKey,
        SamplerSettings.samplerTypeKey,
        SamplerSettings.seedKey,
        SamplerSettings.maxOutputTokensKey,
        SamplerSettings.applyPromptTemplateKey,
        SamplerSettings.enableConstrainedDecodingKey,
        SamplerSettings.parallelFileLoadingKey,
        SamplerSettings.activationDtypeKey,
        SamplerSettings.prefillChunkSizeKey,
        SamplerSettings.speculativeDecodingKey,
        SamplerSettings.debugLogLevelKey,
        SamplerSettings.visionAcceleratorKey,
        SamplerSettings.audioAcceleratorKey,
    ]

    override func setUp() {
        super.setUp()
        for k in touchedKeys { UserDefaults.standard.removeObject(forKey: k) }
    }

    override func tearDown() {
        for k in touchedKeys { UserDefaults.standard.removeObject(forKey: k) }
        super.tearDown()
    }

    /// Settings UI no longer surfaces the advanced-knob toggles, but
    /// SamplerSettings.current() still reads the same keys so non-UI
    /// callers (the eval entry point, debug builds) can override them.
    /// Verify the contract still holds.
    func testAdvancedKnobsStillReadableAfterUIRemoval() {
        UserDefaults.standard.set("cpu", forKey: SamplerSettings.visionAcceleratorKey)
        UserDefaults.standard.set("gpu", forKey: SamplerSettings.audioAcceleratorKey)
        UserDefaults.standard.set(false, forKey: SamplerSettings.applyPromptTemplateKey)
        UserDefaults.standard.set(true, forKey: SamplerSettings.enableConstrainedDecodingKey)
        UserDefaults.standard.set(true, forKey: SamplerSettings.speculativeDecodingKey)
        UserDefaults.standard.set(false, forKey: SamplerSettings.parallelFileLoadingKey)
        UserDefaults.standard.set(2, forKey: SamplerSettings.activationDtypeKey)
        UserDefaults.standard.set(512, forKey: SamplerSettings.prefillChunkSizeKey)
        UserDefaults.standard.set(0, forKey: SamplerSettings.debugLogLevelKey)

        let snap = SamplerSettings.current()
        XCTAssertEqual(snap.visionAccelerator, "cpu")
        XCTAssertEqual(snap.audioAccelerator, "gpu")
        XCTAssertFalse(snap.applyPromptTemplate)
        XCTAssertTrue(snap.enableConstrainedDecoding)
        XCTAssertTrue(snap.speculativeDecoding)
        XCTAssertFalse(snap.parallelFileLoading)
        XCTAssertEqual(snap.activationDtype, 2)
        XCTAssertEqual(snap.prefillChunkSize, 512)
        XCTAssertEqual(snap.debugLogLevel, 0)
    }

    /// Model-tab UI knobs (accelerator / sampler type / seed / max output
    /// tokens) survive a save+restore round trip.
    func testModelTabKnobsRoundTrip() {
        UserDefaults.standard.set("cpu", forKey: SamplerSettings.acceleratorKey)
        UserDefaults.standard.set(1, forKey: SamplerSettings.samplerTypeKey)  // greedy
        UserDefaults.standard.set(42, forKey: SamplerSettings.seedKey)
        UserDefaults.standard.set(512, forKey: SamplerSettings.maxOutputTokensKey)

        let snap = SamplerSettings.current()
        XCTAssertEqual(snap.accelerator, "cpu")
        XCTAssertEqual(snap.samplerType, 1)
        XCTAssertEqual(snap.seed, 42)
        XCTAssertEqual(snap.maxOutputTokens, 512)
    }

    /// Skill manager flow scenario:
    ///  1. fresh install → only built-in skills visible
    ///  2. user adds a custom skill manually via CustomSkillStore (the
    ///     same path the manual path in the manager uses)
    ///  3. catalog now includes the custom row, and toggle persists
    @MainActor
    func testCustomSkillAddThenToggleScenario() async throws {
        let slug = "scenario-\(UUID().uuidString.prefix(6).lowercased())"
        defer {
            try? CustomSkillStore.delete(slug: slug)
            SkillToggles.resetAll()
        }

        // Step 1: catalog before is the built-in set, no custom yet.
        let beforeCustom = SkillBundle.scanCustom().filter { $0.slug == slug }
        XCTAssertTrue(beforeCustom.isEmpty)

        // Step 2: user "adds manually" via the editor → CustomSkillStore.
        try CustomSkillStore.create(CustomSkillDraft(
            slug: slug,
            description: "scenario test",
            instructions: "Do something.",
            jsBody: "window['ai_edge_gallery_get_result']=async(d)=>'ok';"
        ))
        let after = SkillBundle.scanCustom().first { $0.slug == slug }
        XCTAssertNotNil(after, "Custom skill should be discoverable after create")
        XCTAssertEqual(after?.source, .custom)

        // Step 3: toggle off and verify SkillRegistry filters it out of
        // the planner-visible set, while keeping it in the manager view.
        SkillToggles.setEnabled(false, for: slug)
        let registry = SkillRegistry.defaultSet()
        try await Task.sleep(nanoseconds: 50_000_000)
        let visible = Set(registry.getAvailableSkills().map(\.name))
        let everything = Set(registry.allSkills().map(\.name))
        XCTAssertFalse(visible.contains(slug),
                       "Disabled skills must be hidden from the planner")
        XCTAssertTrue(everything.contains(slug),
                      "Manager UI should still see disabled skills")
    }
}
