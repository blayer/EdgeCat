import XCTest
@testable import MobileClaw

final class LlmInitConfigTests: XCTestCase {

    private let url = URL(fileURLWithPath: "/tmp/fake.litertlm")

    func testDefaultsMatchAndroidParity() {
        let cfg = LlmInitConfig(modelPath: url)
        // Engine-level defaults
        XCTAssertEqual(cfg.backend, .cpu,
                       "iOS dylib is CPU-only (cc_binary :engine_cpu) — flip to .gpu when Metal build ships")
        XCTAssertEqual(cfg.visionBackend, .default)
        XCTAssertEqual(cfg.audioBackend, .default)
        XCTAssertEqual(cfg.maxTokens, 1024)
        XCTAssertNil(cfg.cacheDir)
        XCTAssertTrue(cfg.parallelFileSectionLoading)
        XCTAssertEqual(cfg.activationDataType, .default)
        XCTAssertEqual(cfg.prefillChunkSize, 0)
        XCTAssertFalse(cfg.enableSpeculativeDecoding)
        XCTAssertEqual(cfg.logLevel, .silent)

        // Sampler defaults match Gemma 4 metadata
        XCTAssertEqual(cfg.samplerType, .topP)
        XCTAssertEqual(cfg.topK, 40)
        XCTAssertEqual(cfg.topP, 0.95, accuracy: 0.001)
        XCTAssertEqual(cfg.temperature, 1.0, accuracy: 0.001)
        XCTAssertEqual(cfg.seed, 0)
        XCTAssertEqual(cfg.maxOutputTokens, 0)
        XCTAssertTrue(cfg.applyPromptTemplate)

        // Conversation defaults
        XCTAssertNil(cfg.systemInstruction)
        XCTAssertFalse(cfg.enableConstrainedDecoding)
    }

    func testCustomFieldsRoundTrip() {
        let cfg = LlmInitConfig(
            modelPath: url,
            backend: .cpu,
            visionBackend: .gpu,
            audioBackend: .cpu,
            maxTokens: 4096,
            cacheDir: URL(fileURLWithPath: "/tmp/cache"),
            parallelFileSectionLoading: false,
            activationDataType: .f16,
            prefillChunkSize: 256,
            enableSpeculativeDecoding: true,
            logLevel: .verbose,
            samplerType: .greedy,
            topK: 50,
            topP: 0.9,
            temperature: 0.7,
            seed: 42,
            maxOutputTokens: 512,
            applyPromptTemplate: false,
            systemInstruction: "Be concise",
            enableConstrainedDecoding: true
        )
        XCTAssertEqual(cfg.backend, .cpu)
        XCTAssertEqual(cfg.visionBackend, .gpu)
        XCTAssertEqual(cfg.audioBackend, .cpu)
        XCTAssertEqual(cfg.maxTokens, 4096)
        XCTAssertEqual(cfg.cacheDir?.path, "/tmp/cache")
        XCTAssertFalse(cfg.parallelFileSectionLoading)
        XCTAssertEqual(cfg.activationDataType, .f16)
        XCTAssertEqual(cfg.prefillChunkSize, 256)
        XCTAssertTrue(cfg.enableSpeculativeDecoding)
        XCTAssertEqual(cfg.logLevel, .verbose)
        XCTAssertEqual(cfg.samplerType, .greedy)
        XCTAssertEqual(cfg.topK, 50)
        XCTAssertEqual(cfg.topP, 0.9, accuracy: 0.001)
        XCTAssertEqual(cfg.temperature, 0.7, accuracy: 0.001)
        XCTAssertEqual(cfg.seed, 42)
        XCTAssertEqual(cfg.maxOutputTokens, 512)
        XCTAssertFalse(cfg.applyPromptTemplate)
        XCTAssertEqual(cfg.systemInstruction, "Be concise")
        XCTAssertTrue(cfg.enableConstrainedDecoding)
    }

    func testLogLevelRawValuesMatchCApi() {
        // Enums must match the levels documented in c/engine.h:
        // 0=VERBOSE, 1=DEBUG, 2=INFO, 3=WARNING, 4=ERROR, 5=FATAL, 1000=SILENT.
        XCTAssertEqual(LlmLogLevel.verbose.rawValue, 0)
        XCTAssertEqual(LlmLogLevel.debug.rawValue, 1)
        XCTAssertEqual(LlmLogLevel.info.rawValue, 2)
        XCTAssertEqual(LlmLogLevel.warning.rawValue, 3)
        XCTAssertEqual(LlmLogLevel.error.rawValue, 4)
        XCTAssertEqual(LlmLogLevel.fatal.rawValue, 5)
        XCTAssertEqual(LlmLogLevel.silent.rawValue, 1000)
    }
}
