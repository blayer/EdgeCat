import XCTest
@testable import EdgeCat

final class LitertlmImporterTests: XCTestCase {

    private var src: URL!
    private var dst: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let tmp = FileManager.default.temporaryDirectory
        src = tmp.appendingPathComponent("import-src-\(UUID().uuidString).litertlm")
        dst = tmp.appendingPathComponent("import-dst-\(UUID().uuidString).litertlm")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: src)
        try? FileManager.default.removeItem(at: dst)
        super.tearDown()
    }

    func testStreamCopyReproducesBytesExactly() throws {
        // Bigger than one default chunk (4 MB) so the loop iterates and the
        // progress callback fires more than once. A 6 MB blob is enough.
        let payload = Data((0..<(6 * 1024 * 1024)).map { UInt8($0 & 0xFF) })
        try payload.write(to: src)

        var lastProgress: Int64 = 0
        var callbacks = 0
        try LitertlmImporter.streamCopy(source: src, destination: dst,
                                        totalBytes: Int64(payload.count)) { copied in
            callbacks += 1
            XCTAssertGreaterThanOrEqual(copied, lastProgress,
                                         "Progress should be monotonic")
            lastProgress = copied
        }

        XCTAssertGreaterThan(callbacks, 1,
                             "6 MB at default 4 MB chunk size should fire the callback at least twice")
        let copied = try Data(contentsOf: dst)
        XCTAssertEqual(copied, payload,
                       "Streamed copy must produce a byte-exact duplicate")
        XCTAssertEqual(lastProgress, Int64(payload.count),
                       "Final progress must equal total file size")
    }

    func testSmallerThanOneChunkStillWorks() throws {
        // Edge case: a tiny file that finishes in a single read. The
        // progress callback fires exactly once.
        let payload = Data(repeating: 0xAB, count: 1024)
        try payload.write(to: src)

        var calls = 0
        try LitertlmImporter.streamCopy(source: src, destination: dst,
                                        totalBytes: Int64(payload.count),
                                        chunkSize: 4 * 1024 * 1024) { _ in
            calls += 1
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try Data(contentsOf: dst), payload)
    }

    func testCustomChunkSizeIteratesMoreOften() throws {
        let payload = Data(repeating: 0x42, count: 100_000)
        try payload.write(to: src)

        var calls = 0
        try LitertlmImporter.streamCopy(source: src, destination: dst,
                                        totalBytes: Int64(payload.count),
                                        chunkSize: 1024) { _ in
            calls += 1
        }
        // 100,000 / 1024 ≈ 98 chunks → ~98 callbacks. Be lenient with a
        // lower bound since the final partial chunk also counts.
        XCTAssertGreaterThan(calls, 50)
        XCTAssertEqual(try Data(contentsOf: dst), payload)
    }
}
