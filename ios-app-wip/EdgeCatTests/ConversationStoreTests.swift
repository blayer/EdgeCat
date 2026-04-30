import XCTest
import SwiftData
@testable import EdgeCat

@MainActor
final class ConversationStoreTests: XCTestCase {
    private var container: ModelContainer?
    private var context: ModelContext?
    private var store: ConversationStore?

    override func setUp() async throws {
        try await super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Conversation.self, StoredMessage.self,
                                       configurations: config)
        let container = try XCTUnwrap(container)
        context = ModelContext(container)
        store = ConversationStore(context: try XCTUnwrap(context))
    }

    override func tearDown() async throws {
        store = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    func testCreateConversationInsertsAndPersists() throws {
        let store = try XCTUnwrap(store)
        let context = try XCTUnwrap(context)
        let conv = try store.createConversation()
        XCTAssertEqual(conv.title, "")
        XCTAssertEqual(conv.messageCount, 0)
        XCTAssertFalse(conv.pinned)

        let descriptor = FetchDescriptor<Conversation>()
        let all = try context.fetch(descriptor)
        XCTAssertEqual(all.count, 1)
    }

    func testDeleteConversationCascades() throws {
        let store = try XCTUnwrap(store)
        let context = try XCTUnwrap(context)
        let conv = try store.createConversation()
        try store.appendMessage(to: conv, role: "user", content: "hello")
        try store.appendMessage(to: conv, role: "assistant", content: "hi back")

        let beforeMsgs = try context.fetch(FetchDescriptor<StoredMessage>())
        XCTAssertEqual(beforeMsgs.count, 2)

        try store.deleteConversation(conv)

        let afterConvs = try context.fetch(FetchDescriptor<Conversation>())
        XCTAssertTrue(afterConvs.isEmpty)
        let afterMsgs = try context.fetch(FetchDescriptor<StoredMessage>())
        XCTAssertTrue(afterMsgs.isEmpty, "Cascade delete should remove orphaned messages")
    }

    func testSetPinnedTimestamp() throws {
        let store = try XCTUnwrap(store)
        let conv = try store.createConversation()
        try store.setPinned(conv, true)
        XCTAssertTrue(conv.pinned)
        XCTAssertNotNil(conv.pinnedAt)

        try store.setPinned(conv, false)
        XCTAssertFalse(conv.pinned)
        XCTAssertNil(conv.pinnedAt)
    }

    func testAppendMessageUpdatesConversationMetadata() throws {
        let store = try XCTUnwrap(store)
        let conv = try store.createConversation()
        let originalUpdated = conv.updatedAt
        Thread.sleep(forTimeInterval: 0.01)

        try store.appendMessage(to: conv, role: "user",
                                content: "this is the very first message of the thread")
        XCTAssertEqual(conv.messageCount, 1)
        XCTAssertEqual(conv.title, "this is the very first message of the thread")
        XCTAssertTrue(conv.lastMessagePreview.hasPrefix("this is the very first"))
        XCTAssertGreaterThan(conv.updatedAt, originalUpdated)
    }

    func testAppendMessageWithImagesAndAudioPersistsBlobs() throws {
        let store = try XCTUnwrap(store)
        let conv = try store.createConversation()
        let img = Data(repeating: 0x42, count: 32)
        let aud = Data(repeating: 0x77, count: 64)
        try store.appendMessage(to: conv, role: "user", content: "see this",
                                images: [img], audio: [aud])
        let messages = store.messages(in: conv)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].imageBlobs?.first, img)
        XCTAssertEqual(messages[0].audioBlobs?.first, aud)
    }

    func testTitleAssignedOnFirstUserMessageOnly() throws {
        let store = try XCTUnwrap(store)
        let conv = try store.createConversation()
        try store.appendMessage(to: conv, role: "user", content: "first")
        try store.appendMessage(to: conv, role: "user", content: "second")
        XCTAssertEqual(conv.title, "first")
    }

    func testMessagesSortedByCreatedAt() throws {
        let store = try XCTUnwrap(store)
        let conv = try store.createConversation()
        try store.appendMessage(to: conv, role: "user", content: "msg1")
        Thread.sleep(forTimeInterval: 0.01)
        try store.appendMessage(to: conv, role: "assistant", content: "reply1")
        Thread.sleep(forTimeInterval: 0.01)
        try store.appendMessage(to: conv, role: "user", content: "msg2")
        let ordered = store.messages(in: conv)
        XCTAssertEqual(ordered.map(\.content), ["msg1", "reply1", "msg2"])
    }

    func testSystemPromptOverrideRoundTrip() throws {
        let store = try XCTUnwrap(store)
        let context = try XCTUnwrap(context)
        let conv = try store.createConversation()
        XCTAssertNil(conv.systemPromptOverride)
        conv.systemPromptOverride = "Be concise"
        try context.save()

        let descriptor = FetchDescriptor<Conversation>()
        let fetched = try context.fetch(descriptor)
        XCTAssertEqual(fetched.first?.systemPromptOverride, "Be concise")
    }
}
