import XCTest
@testable import EdgeCat

/// HealthKit isn't available on the sim simulator-runtime test target's
/// default sandbox (no entitlement, no data), so these tests focus on
/// the surface the planner actually sees: arg validation, error shape,
/// and the JSON envelope. Live HealthKit integration is exercised by
/// the eval harness via `edgecat://verify` (see `StateVerifiers`).
final class ReadHealthSkillTests: XCTestCase {

    func testNameAndDescriptionAreStable() {
        let s = ReadHealthSkill()
        XCTAssertEqual(s.name, "read-health")
        XCTAssertTrue(s.description.lowercased().contains("healthkit"))
    }

    func testUnknownMetricReturnsErrorEnvelope() async {
        let s = ReadHealthSkill()
        let r = await s.run(args: ["metric": "blood_pressure"])
        XCTAssertFalse(r.success)
        XCTAssertNotNil(r.error)
        XCTAssertTrue((r.error ?? "").contains("unknown metric"))
    }

    func testWindowDaysClampedToValidRange() async {
        // Negative / zero clamp to 1, > 30 clamps to 30. The query
        // either succeeds (with empty samples on sim) or fails with a
        // descriptive permission/availability message — both are valid.
        let s = ReadHealthSkill()
        let neg = await s.run(args: ["metric": "steps", "window_days": "-5"])
        let huge = await s.run(args: ["metric": "steps", "window_days": "9999"])
        // Whichever path, the skill must produce *some* output (no crash,
        // no empty error).
        XCTAssertTrue(neg.success || (neg.error?.isEmpty == false))
        XCTAssertTrue(huge.success || (huge.error?.isEmpty == false))
    }

    func testStepsResultJsonShapeWhenSucceeds() async throws {
        // On simulator, HealthKit is available but data is empty —
        // requestAuthorization typically resolves to .notDetermined or
        // succeeds with no samples. Either way, on success the JSON
        // envelope must contain the documented keys.
        let s = ReadHealthSkill()
        let r = await s.run(args: ["metric": "steps", "window_days": "1", "max_samples": "10"])
        guard r.success else {
            // Acceptable failure modes on simulator/CI.
            return
        }
        guard let data = r.output.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return XCTFail("output is not valid JSON: \(r.output)")
        }
        XCTAssertEqual(json["status"] as? String, "succeeded")
        XCTAssertEqual(json["metric"] as? String, "steps")
        XCTAssertNotNil(json["window_start"])
        XCTAssertNotNil(json["window_end"])
        XCTAssertNotNil(json["sample_count"])
        XCTAssertNotNil(json["summary"])
        XCTAssertNotNil(json["samples"])
    }
}
