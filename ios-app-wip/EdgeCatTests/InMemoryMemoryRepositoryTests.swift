import XCTest
@testable import EdgeCat

final class InMemoryMemoryRepositoryTests: XCTestCase {

    func testRecallEmptyByDefault() async {
        let repo = InMemoryMemoryRepository()
        let result = await repo.recallForPlanning(userMessage: "hi", tokenBudget: 1024)
        XCTAssertEqual(result, "")
    }

    func testSaveAndRecallByExactPhrase() async {
        let repo = InMemoryMemoryRepository()
        await repo.save(episode: Episode(userMessage: "set timer for 10 minutes",
                                         goal: "set timer for 10 minutes",
                                         skillsUsed: ["set-timer"],
                                         outcome: "success", stepCount: 1,
                                         finalOutput: "Timer set"))
        let recall = await repo.recallForPlanning(userMessage: "set timer", tokenBudget: 1024)
        XCTAssertTrue(recall.contains("set timer for 10 minutes"))
        XCTAssertTrue(recall.contains("success"))
        XCTAssertTrue(recall.contains("set-timer"))
    }

    func testRecallCappedAtThree() async {
        let repo = InMemoryMemoryRepository()
        for i in 0..<10 {
            await repo.save(episode: Episode(userMessage: "weather query \(i)",
                                             goal: "find the weather",
                                             skillsUsed: ["fetch-web"],
                                             outcome: "success", stepCount: 1,
                                             finalOutput: "..."))
        }
        let recall = await repo.recallForPlanning(userMessage: "weather", tokenBudget: 1024)
        let count = recall.split(separator: "\n").count
        XCTAssertEqual(count, 3)
    }

    func testRecallRepairsByMatchingError() async {
        let repo = InMemoryMemoryRepository()
        await repo.save(repair: RepairRecord(skillName: "calendar",
                                             errorSummary: "permission denied",
                                             fixType: "use_alternative_skill",
                                             fixDescription: "fall back to reminders",
                                             alternativeSkill: "reminders",
                                             alternativeArgs: ["title": "x"],
                                             success: true))
        await repo.save(repair: RepairRecord(skillName: "calendar",
                                             errorSummary: "store offline",
                                             fixType: "retry_with_different_args",
                                             fixDescription: "retry",
                                             success: false))
        let result = await repo.recallRepairs(skillName: "calendar",
                                              error: "permission denied", limit: 5)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.fixType, "use_alternative_skill")
    }

    func testRecallRepairsLimits() async {
        let repo = InMemoryMemoryRepository()
        for _ in 0..<10 {
            await repo.save(repair: RepairRecord(skillName: "calendar",
                                                 errorSummary: "permission denied",
                                                 fixType: "x", fixDescription: "y",
                                                 success: true))
        }
        let result = await repo.recallRepairs(skillName: "calendar",
                                              error: "permission", limit: 3)
        XCTAssertEqual(result.count, 3)
    }

    func testDeviceFactsUpsert() async {
        let repo = InMemoryMemoryRepository()
        await repo.saveDeviceFact(key: "user_name", value: "Lin", sourceEpisodeId: nil)
        await repo.saveDeviceFact(key: "user_name", value: "Lin Z.", sourceEpisodeId: "ep1")
        let facts = await repo.getDeviceFacts()
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts.first?.factValue, "Lin Z.")
        XCTAssertEqual(facts.first?.sourceEpisodeId, "ep1")
    }

    func testClearAllDropsEverything() async {
        let repo = InMemoryMemoryRepository()
        await repo.save(episode: Episode(userMessage: "x", goal: "x",
                                         skillsUsed: [], outcome: "success",
                                         stepCount: 0, finalOutput: ""))
        await repo.save(repair: RepairRecord(skillName: "s", errorSummary: "e",
                                             fixType: "t", fixDescription: "d",
                                             success: true))
        await repo.saveDeviceFact(key: "k", value: "v", sourceEpisodeId: nil)
        await repo.clearAll()
        let recall = await repo.recallForPlanning(userMessage: "x", tokenBudget: 1024)
        XCTAssertEqual(recall, "")
        let repairs = await repo.recallRepairs(skillName: "s", error: "e", limit: 5)
        XCTAssertTrue(repairs.isEmpty)
        let facts = await repo.getDeviceFacts()
        XCTAssertTrue(facts.isEmpty)
    }

    func testEvictionCapsEpisodesAndRepairs() async {
        let repo = InMemoryMemoryRepository()
        for i in 0..<1500 {
            await repo.save(episode: Episode(userMessage: "msg \(i)", goal: "goal",
                                             skillsUsed: [], outcome: "success",
                                             stepCount: 0, finalOutput: ""))
            await repo.save(repair: RepairRecord(skillName: "s", errorSummary: "e\(i)",
                                                 fixType: "t", fixDescription: "d",
                                                 success: true))
        }
        await repo.evictIfNeeded(maxSizeBytes: 100 * 1024 * 1024)
        // After eviction, only the last 1000 of each are retained. Recall on
        // the most recent (msg 1499) still surfaces; recall on msg 0 returns
        // empty because it was evicted.
        let recent = await repo.recallForPlanning(userMessage: "msg 1499", tokenBudget: 1024)
        XCTAssertTrue(recent.contains("msg 1499"))
        let stale = await repo.recallForPlanning(userMessage: "msg 0 only-edge-case", tokenBudget: 1024)
        XCTAssertEqual(stale, "")
    }
}
