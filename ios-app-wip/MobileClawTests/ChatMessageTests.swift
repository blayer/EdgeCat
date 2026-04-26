import XCTest
@testable import MobileClaw

final class ChatMessageTests: XCTestCase {

    func testDefaultsArePopulated() {
        let m = ChatMessage(role: .user, text: "hi")
        XCTAssertNotEqual(m.id.uuidString, "")
        XCTAssertEqual(m.role, .user)
        XCTAssertEqual(m.kind, .text)
        XCTAssertNil(m.thought)
        XCTAssertTrue(m.images.isEmpty)
        XCTAssertTrue(m.audio.isEmpty)
        XCTAssertNil(m.latencyMs)
    }

    func testEqualityAcrossSameContent() {
        let id = UUID()
        let date = Date()
        let a = ChatMessage(id: id, role: .assistant, text: "hi", createdAt: date)
        let b = ChatMessage(id: id, role: .assistant, text: "hi", createdAt: date)
        XCTAssertEqual(a, b)
    }

    func testInequalityWhenIdDiffers() {
        let date = Date()
        let a = ChatMessage(role: .assistant, text: "hi", createdAt: date)
        let b = ChatMessage(role: .assistant, text: "hi", createdAt: date)
        XCTAssertNotEqual(a, b, "Distinct ids → distinct messages")
    }

    func testKindCases() {
        XCTAssertNotEqual(ChatMessage.Kind.text, .loading)
        XCTAssertNotEqual(ChatMessage.Kind.text, .error)
        XCTAssertNotEqual(ChatMessage.Kind.thinking, .text)
    }

    func testMessageRoleStringRawValues() {
        XCTAssertEqual(MessageRole.user.rawValue, "user")
        XCTAssertEqual(MessageRole.assistant.rawValue, "assistant")
        XCTAssertEqual(MessageRole.system.rawValue, "system")
    }

    func testImagesAndAudioPreserved() {
        let img = Data(repeating: 1, count: 3)
        let aud = Data(repeating: 2, count: 4)
        let m = ChatMessage(role: .user, text: "see", images: [img], audio: [aud])
        XCTAssertEqual(m.images, [img])
        XCTAssertEqual(m.audio, [aud])
    }
}
