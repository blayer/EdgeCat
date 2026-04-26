import XCTest
import SwiftData
@testable import MobileClaw

@MainActor
final class SwiftDataMemoryRepositoryTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var repo: SwiftDataMemoryRepository!

    override func setUp() async throws {
        try await super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: EpisodeEntity.self, RepairRecordEntity.self,
                                       DeviceFactEntity.self,
                                       configurations: config)
        context = ModelContext(container)
        repo = SwiftDataMemoryRepository(context: context)
        FtsIndex.shared.clear()
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    override func tearDown() async throws {
        repo = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    func testSaveAndRecallEpisode() async throws {
        await repo.save(episode: Episode(userMessage: "what's the time in tokyo",
                                         goal: "tokyo time",
                                         skillsUsed: ["search-web"],
                                         outcome: "success", stepCount: 1,
                                         finalOutput: "9 PM"))
        // Allow FTS async to drain.
        try await Task.sleep(nanoseconds: 150_000_000)
        let recall = await repo.recallForPlanning(userMessage: "tokyo", tokenBudget: 1024)
        XCTAssertTrue(recall.contains("tokyo"))
        XCTAssertTrue(recall.contains("success"))
    }

    func testSubstringFallbackWorksWithoutFts() async throws {
        // Even if FTS misses, substring fallback in the repo should hit.
        await repo.save(episode: Episode(userMessage: "find pizza nearby",
                                         goal: "pizza", skillsUsed: [],
                                         outcome: "partial", stepCount: 1,
                                         finalOutput: ""))
        try await Task.sleep(nanoseconds: 150_000_000)
        let r = await repo.recallForPlanning(userMessage: "pizza", tokenBudget: 1024)
        XCTAssertTrue(r.contains("pizza"))
    }

    func testRepairsRoundTrip() async {
        await repo.save(repair: RepairRecord(skillName: "calendar",
                                             errorSummary: "permission denied",
                                             fixType: "alt",
                                             fixDescription: "use reminders",
                                             alternativeSkill: "reminders",
                                             alternativeArgs: ["title": "x"],
                                             success: true))
        let r = await repo.recallRepairs(skillName: "calendar",
                                          error: "permission", limit: 5)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.first?.alternativeSkill, "reminders")
        XCTAssertEqual(r.first?.alternativeArgs["title"], "x")
    }

    func testDeviceFactsUpsertOnDuplicateKey() async {
        await repo.saveDeviceFact(key: "user_name", value: "Lin", sourceEpisodeId: nil)
        await repo.saveDeviceFact(key: "user_name", value: "Lin Z.", sourceEpisodeId: "ep1")
        let facts = await repo.getDeviceFacts()
        XCTAssertEqual(facts.count, 1, "factKey @Attribute(.unique) should upsert")
        XCTAssertEqual(facts.first?.factValue, "Lin Z.")
        XCTAssertEqual(facts.first?.sourceEpisodeId, "ep1")
    }

    func testEvictionRemovesOldestBeyondCap() async throws {
        // The cap inside repo is 1000; insert 1010 to verify eviction trims.
        // We can't easily verify exact 1000 inside an in-memory store without
        // probing the entity count, so just verify it shrinks to cap.
        for i in 0..<1010 {
            await repo.save(episode: Episode(userMessage: "msg \(i)", goal: "g",
                                             skillsUsed: [], outcome: "success",
                                             stepCount: 0, finalOutput: ""))
        }
        await repo.evictIfNeeded(maxSizeBytes: 1)
        let count = (try? context.fetch(FetchDescriptor<EpisodeEntity>()).count) ?? -1
        XCTAssertLessThanOrEqual(count, 1000, "Eviction should cap at 1000 episodes")
    }

    func testClearAllRemovesEverything() async {
        await repo.save(episode: Episode(userMessage: "x", goal: "y",
                                         skillsUsed: [], outcome: "success",
                                         stepCount: 0, finalOutput: ""))
        await repo.save(repair: RepairRecord(skillName: "s", errorSummary: "e",
                                             fixType: "t", fixDescription: "d",
                                             success: true))
        await repo.saveDeviceFact(key: "k", value: "v", sourceEpisodeId: nil)
        await repo.clearAll()
        XCTAssertTrue((try? context.fetch(FetchDescriptor<EpisodeEntity>()))?.isEmpty == true)
        XCTAssertTrue((try? context.fetch(FetchDescriptor<RepairRecordEntity>()))?.isEmpty == true)
        XCTAssertTrue((try? context.fetch(FetchDescriptor<DeviceFactEntity>()))?.isEmpty == true)
    }
}
