import XCTest
@testable import MobileClaw

final class MemoryEntitiesTests: XCTestCase {

    func testEpisodeCodableRoundTrip() throws {
        let original = Episode(id: "ep-1", userMessage: "u", goal: "g",
                               skillsUsed: ["a", "b"], outcome: "success",
                               stepCount: 2, finalOutput: "done")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Episode.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testRepairRecordCodableRoundTrip() throws {
        let original = RepairRecord(id: "r1", skillName: "calendar",
                                    errorSummary: "perm", fixType: "alt",
                                    fixDescription: "use reminders",
                                    alternativeSkill: "reminders",
                                    alternativeArgs: ["title": "x"],
                                    success: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RepairRecord.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testDeviceFactCodableRoundTrip() throws {
        let original = DeviceFact(id: "f1", factKey: "user_name",
                                  factValue: "Lin", sourceEpisodeId: "ep1")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DeviceFact.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testEpisodeAutoIdIsUUID() {
        let e = Episode(userMessage: "x", goal: "y", skillsUsed: [],
                        outcome: "success", stepCount: 0, finalOutput: "")
        XCTAssertNotNil(UUID(uuidString: e.id),
                        "Default id should be a UUID string")
    }
}
