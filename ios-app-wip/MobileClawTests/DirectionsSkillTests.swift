import XCTest
@testable import MobileClaw

/// MKDirections requires network for geocoding and routing; CI / sim
/// without an internet route can't actually compute a route. These
/// tests focus on the deterministic surface: arg validation, mode
/// mapping, and error shapes.
final class DirectionsSkillTests: XCTestCase {

    func testNameAndDescriptionAreStable() {
        let s = DirectionsSkill()
        XCTAssertEqual(s.name, "directions")
        XCTAssertTrue(s.description.lowercased().contains("directions"))
    }

    func testMissingToReturnsErrorEnvelope() async {
        let s = DirectionsSkill()
        let r = await s.run(args: [:])
        XCTAssertFalse(r.success)
        XCTAssertEqual(r.error, "missing 'to' argument")
    }

    func testEmptyToReturnsErrorEnvelope() async {
        let s = DirectionsSkill()
        let r = await s.run(args: ["to": ""])
        XCTAssertFalse(r.success)
        XCTAssertEqual(r.error, "missing 'to' argument")
    }

    func testUnreachableNonsenseGeocodeReportsClearError() async {
        // The named query has no plausible match — MKLocalSearch should
        // resolve to "no match for …". We don't assert the exact wording
        // (geocoding behavior varies), only that we get a non-empty
        // error string and not a crash.
        let s = DirectionsSkill()
        let r = await s.run(args: [
            "from": "this-place-does-not-exist-1234567890-XYZQQ",
            "to":   "and-neither-does-this-9876543210-ABCEE",
        ])
        XCTAssertFalse(r.success)
        XCTAssertNotNil(r.error)
        XCTAssertFalse((r.error ?? "").isEmpty)
    }
}
