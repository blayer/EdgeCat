import XCTest
@testable import MobileClaw

/// Coverage for the 9 newly-ported native skills. We focus on:
///   - Argument validation (missing / malformed inputs return failure)
///   - The non-platform-side behavior (URL composition, text routing) so
///     CI can run these without UIApplication / PhotoKit / notifications
///     authorization. Anything that requires a real iOS user prompt
///     (PHPhotoLibrary, UNUserNotificationCenter authorization) is
///     skipped — the device-side smoke is documented in the PR plan.
final class NewNativeSkillsTests: XCTestCase {

    // MARK: - OpenUrlSkill

    func testOpenUrlRejectsMissingArg() async {
        let result = await OpenUrlSkill().run(args: [:])
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("url") == true)
    }

    func testOpenUrlRejectsBlankArg() async {
        let result = await OpenUrlSkill().run(args: ["url": "   "])
        XCTAssertFalse(result.success)
    }

    // MARK: - OpenSettingsSkill

    func testOpenSettingsHasFriendlyDescription() {
        let skill = OpenSettingsSkill()
        XCTAssertEqual(skill.name, "open-settings")
        // Should mention iOS limitation so the planner doesn't try to
        // route to "Wi-Fi settings" / "Bluetooth settings" via this skill.
        XCTAssertTrue(skill.description.contains("Settings"))
    }

    // MARK: - SendEmailSkill

    func testSendEmailRejectsMissingTo() async {
        let result = await SendEmailSkill().run(args: ["subject": "x", "body": "y"])
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("to") == true)
    }

    // MARK: - LaunchAppSkill

    func testLaunchAppRejectsMissingArg() async {
        let result = await LaunchAppSkill().run(args: [:])
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("appName") == true)
    }

    func testLaunchAppKnownAliasFallsThroughToCanOpen() async {
        // We can't assert the system actually opened anything from the
        // simulator, but the failure should be the no-handler error
        // (proving the alias mapping kicked in), not an args error.
        let result = await LaunchAppSkill().run(args: ["appName": "messages"])
        if !result.success {
            XCTAssertTrue(result.error?.contains("not installed") == true ||
                           result.error?.contains("scheme") == true,
                           "Expected a scheme/handler error, got: \(result.error ?? "nil")")
        }
    }

    // MARK: - TimerSkill

    func testTimerRejectsUnknownAction() async {
        let result = await TimerSkill().run(args: ["action": "explode"])
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("unknown action") == true)
    }

    func testTimerStartRejectsMissingDuration() async {
        let result = await TimerSkill().run(args: ["action": "start", "label": "tea"])
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("seconds") == true ||
                       result.error?.contains("permission denied") == true,
                       "Got: \(result.error ?? "nil")")
    }

    func testTimerCancelRejectsMissingId() async {
        let result = await TimerSkill().run(args: ["action": "cancel"])
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("id") == true)
    }

    // MARK: - ListDownloadsSkill

    func testListDownloadsReturnsValidJsonShape() async {
        let result = await ListDownloadsSkill().run(args: [:])
        XCTAssertTrue(result.success)
        // Output is "<status header>\n<json>" — extract the JSON portion
        // (the skill prepends a status line for verifier-regex matching;
        // see ListDownloadsSkill.swift).
        let json = jsonPortion(of: result.output)
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Output not valid JSON: \(result.output)"); return
        }
        XCTAssertEqual(obj["status"] as? String, "succeeded")
        XCTAssertNotNil(obj["count"])
        XCTAssertNotNil(obj["items"])
    }

    func testListDownloadsRespectsMaxResults() async {
        let result = await ListDownloadsSkill().run(args: ["maxResults": "1"])
        XCTAssertTrue(result.success)
        let json = jsonPortion(of: result.output)
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let count = obj["count"] as? Int else {
            XCTFail("Bad JSON"); return
        }
        XCTAssertLessThanOrEqual(count, 1)
    }

    private func jsonPortion(of output: String) -> String {
        guard let brace = output.firstIndex(of: "{") else { return output }
        return String(output[brace...])
    }

    // MARK: - Stubs (TakePhoto / VolumeControl)

    func testTakePhotoStubReturnsNotSupported() async {
        let result = await TakePhotoSkill().run(args: [:])
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("not_supported_on_ios") == true)
    }

    func testVolumeControlStubReturnsNotSupported() async {
        let result = await VolumeControlSkill().run(args: ["streamType": "media", "volumePercent": "50"])
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("not_supported_on_ios") == true)
    }

    // MARK: - Registry registration

    @MainActor
    func testAllSkillsRegisteredInDefaultSet() {
        let registry = SkillRegistry.defaultSet()
        let names = Set(registry.allSkills().map { $0.name })
        // Every name in SkillTools.native must have a registered Skill so
        // the planner doesn't emit a name that routes to "unknown skill".
        for name in SkillTools.native.keys {
            XCTAssertTrue(names.contains(name),
                          "Skill '\(name)' is in NATIVE_SKILL_TOOLS but not registered in SkillRegistry.defaultSet()")
        }
    }
}
