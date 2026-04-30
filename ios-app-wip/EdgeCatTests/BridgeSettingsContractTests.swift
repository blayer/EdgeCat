import XCTest
@testable import EdgeCat
import LiteRtLmBridge

/// Contract tests for `LRTLMEngineSettings` + `LRTLMSamplerParams` Obj-C
/// surface. We don't actually load a model — that requires the gigabyte
/// Gemma 4 file the tests don't have. Instead we verify that:
///  1. The Obj-C settings object constructs with sane defaults.
///  2. Every field stays writable from Swift.
///  3. `LRTLMEngine -initWithSettings:error:` returns nil + a non-nil error
///     for an invalid path (it must NOT crash; the Settings UI will hand
///     these straight from UserDefaults).
final class BridgeSettingsContractTests: XCTestCase {

    func testEngineSettingsDefaults() {
        let s = LRTLMEngineSettings(modelPath: "/tmp/fake.litertlm")
        XCTAssertEqual(s.modelPath, "/tmp/fake.litertlm")
        XCTAssertEqual(s.backend, .GPU,
                       "Default backend matches Android's DEFAULT_ACCELERATORS=[GPU]")
        XCTAssertEqual(s.visionBackend, .default)
        XCTAssertEqual(s.audioBackend, .default)
        XCTAssertEqual(s.maxTokens, 0)
        XCTAssertNil(s.cacheDir)
        XCTAssertTrue(s.parallelFileSectionLoading)
        XCTAssertEqual(s.activationDataType, .default)
        XCTAssertEqual(s.prefillChunkSize, 0)
        XCTAssertFalse(s.enableSpeculativeDecoding)
        XCTAssertEqual(s.logLevel, .silent)
    }

    func testSamplerParamsDefaults() {
        let p = LRTLMSamplerParams()
        XCTAssertEqual(p.type, .topP)
        XCTAssertEqual(p.topK, 40)
        XCTAssertEqual(p.topP, 0.95, accuracy: 0.001)
        XCTAssertEqual(p.temperature, 1.0, accuracy: 0.001)
        XCTAssertEqual(p.seed, 0)
    }

    func testEngineSettingsAllFieldsWritable() {
        let s = LRTLMEngineSettings(modelPath: "/tmp/x")
        s.backend = .CPU
        s.visionBackend = .GPU
        s.audioBackend = .CPU
        s.maxTokens = 4096
        s.cacheDir = "/tmp/cache"
        s.parallelFileSectionLoading = false
        s.activationDataType = .F16
        s.prefillChunkSize = 256
        s.enableSpeculativeDecoding = true
        s.logLevel = .verbose
        XCTAssertEqual(s.backend, .CPU)
        XCTAssertEqual(s.visionBackend, .GPU)
        XCTAssertEqual(s.audioBackend, .CPU)
        XCTAssertEqual(s.maxTokens, 4096)
        XCTAssertEqual(s.cacheDir, "/tmp/cache")
        XCTAssertFalse(s.parallelFileSectionLoading)
        XCTAssertEqual(s.activationDataType, .F16)
        XCTAssertEqual(s.prefillChunkSize, 256)
        XCTAssertTrue(s.enableSpeculativeDecoding)
        XCTAssertEqual(s.logLevel, .verbose)
    }

    /// Asserts that init throws an `LRTLMErrorDomain` error for an invalid
    /// model path — must not crash. Swift bridges the bridge's
    /// `-initWithSettings:error:` to `init(settings:) throws`, so we test via
    /// `XCTAssertThrowsError` rather than the legacy &err out-param dance.
    private func assertInitThrows(backend: LRTLMBackend,
                                  file: StaticString = #file,
                                  line: UInt = #line) {
        let s = LRTLMEngineSettings(modelPath: "/nonexistent/\(UUID().uuidString).litertlm")
        s.backend = backend
        XCTAssertThrowsError(try LRTLMEngine(settings: s), file: file, line: line) { err in
            let nsErr = err as NSError
            XCTAssertEqual(nsErr.domain, LRTLMErrorDomain, file: file, line: line)
        }
    }

    func testInvalidModelPathThrows_CPU()     { assertInitThrows(backend: .CPU) }
    func testInvalidModelPathThrows_GPU()     { assertInitThrows(backend: .GPU) }
    func testInvalidModelPathThrows_Default() { assertInitThrows(backend: .default) }

    func testEmptyModelPathThrows() {
        let s = LRTLMEngineSettings(modelPath: "")
        XCTAssertThrowsError(try LRTLMEngine(settings: s))
    }
}
