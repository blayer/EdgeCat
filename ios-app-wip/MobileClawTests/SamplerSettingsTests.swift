import XCTest
@testable import MobileClaw

final class SamplerSettingsTests: XCTestCase {
    private var defaults: UserDefaults?
    private let suiteName = "SamplerSettingsTests-\(UUID().uuidString)"

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        try XCTUnwrap(defaults).removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultsMatchGemma4Recommendations() {
        XCTAssertEqual(SamplerSettings.defaults.topK, 40)
        XCTAssertEqual(SamplerSettings.defaults.topP, 0.95, accuracy: 0.001)
        XCTAssertEqual(SamplerSettings.defaults.temperature, 1.0, accuracy: 0.001)
        XCTAssertEqual(SamplerSettings.defaults.maxTokens, 1024)
    }

    func testAgentDefaults() {
        XCTAssertEqual(SamplerSettings.agentDefaults.maxLoops, 3)
        XCTAssertEqual(SamplerSettings.agentDefaults.maxRepair, 2)
        XCTAssertEqual(SamplerSettings.agentDefaults.skillTimeoutSecs, 60)
        XCTAssertEqual(SamplerSettings.agentDefaults.thinkingMode, 0)
        XCTAssertEqual(SamplerSettings.agentDefaults.historyWindow, 6)
        XCTAssertEqual(SamplerSettings.agentDefaults.traces, true)
    }

    func testCurrentReturnsDefaultsWhenUnset() {
        UserDefaults.standard.removeObject(forKey: SamplerSettings.topKKey)
        UserDefaults.standard.removeObject(forKey: SamplerSettings.topPKey)
        UserDefaults.standard.removeObject(forKey: SamplerSettings.temperatureKey)
        UserDefaults.standard.removeObject(forKey: SamplerSettings.maxTokensKey)
        UserDefaults.standard.removeObject(forKey: SamplerSettings.systemPromptKey)
        let snap = SamplerSettings.current()
        XCTAssertEqual(snap.topK, 40)
        XCTAssertEqual(snap.topP, 0.95, accuracy: 0.001)
        XCTAssertEqual(snap.temperature, 1.0, accuracy: 0.001)
        XCTAssertEqual(snap.maxTokens, 1024)
        XCTAssertEqual(snap.systemPrompt, "")
    }

    func testCurrentRespectsOverriddenValues() {
        UserDefaults.standard.set(7, forKey: SamplerSettings.topKKey)
        UserDefaults.standard.set(0.6, forKey: SamplerSettings.topPKey)
        UserDefaults.standard.set(0.5, forKey: SamplerSettings.temperatureKey)
        UserDefaults.standard.set(2048, forKey: SamplerSettings.maxTokensKey)
        UserDefaults.standard.set("Be concise", forKey: SamplerSettings.systemPromptKey)
        defer {
            UserDefaults.standard.removeObject(forKey: SamplerSettings.topKKey)
            UserDefaults.standard.removeObject(forKey: SamplerSettings.topPKey)
            UserDefaults.standard.removeObject(forKey: SamplerSettings.temperatureKey)
            UserDefaults.standard.removeObject(forKey: SamplerSettings.maxTokensKey)
            UserDefaults.standard.removeObject(forKey: SamplerSettings.systemPromptKey)
        }
        let snap = SamplerSettings.current()
        XCTAssertEqual(snap.topK, 7)
        XCTAssertEqual(snap.topP, 0.6, accuracy: 0.001)
        XCTAssertEqual(snap.temperature, 0.5, accuracy: 0.001)
        XCTAssertEqual(snap.maxTokens, 2048)
        XCTAssertEqual(snap.systemPrompt, "Be concise")
    }

    func testAgentSnapshotFields() {
        UserDefaults.standard.set(7, forKey: SamplerSettings.agentMaxLoopsKey)
        UserDefaults.standard.set(4, forKey: SamplerSettings.agentMaxRepairKey)
        UserDefaults.standard.set(120, forKey: SamplerSettings.agentSkillTimeoutKey)
        UserDefaults.standard.set(2, forKey: SamplerSettings.agentThinkingModeKey)
        UserDefaults.standard.set(10, forKey: SamplerSettings.agentHistoryWindowKey)
        UserDefaults.standard.set(false, forKey: SamplerSettings.agentTracesKey)
        UserDefaults.standard.set("test portrait", forKey: SamplerSettings.userPortraitKey)
        defer {
            UserDefaults.standard.removeObject(forKey: SamplerSettings.agentMaxLoopsKey)
            UserDefaults.standard.removeObject(forKey: SamplerSettings.agentMaxRepairKey)
            UserDefaults.standard.removeObject(forKey: SamplerSettings.agentSkillTimeoutKey)
            UserDefaults.standard.removeObject(forKey: SamplerSettings.agentThinkingModeKey)
            UserDefaults.standard.removeObject(forKey: SamplerSettings.agentHistoryWindowKey)
            UserDefaults.standard.removeObject(forKey: SamplerSettings.agentTracesKey)
            UserDefaults.standard.removeObject(forKey: SamplerSettings.userPortraitKey)
        }
        let snap = SamplerSettings.current()
        XCTAssertEqual(snap.agentMaxLoops, 7)
        XCTAssertEqual(snap.agentMaxRepair, 4)
        XCTAssertEqual(snap.agentSkillTimeoutSecs, 120)
        XCTAssertEqual(snap.agentThinkingMode, 2)
        XCTAssertEqual(snap.agentHistoryWindow, 10)
        XCTAssertFalse(snap.agentTraces)
        XCTAssertEqual(snap.userPortrait, "test portrait")
    }

    func testTracesAndPortraitDefaults() {
        UserDefaults.standard.removeObject(forKey: SamplerSettings.agentTracesKey)
        UserDefaults.standard.removeObject(forKey: SamplerSettings.userPortraitKey)
        let snap = SamplerSettings.current()
        XCTAssertTrue(snap.agentTraces, "Traces default to on, matching Android")
        XCTAssertEqual(snap.userPortrait, "")
    }

    // MARK: - Model knob defaults (added in the bridge audit)

    func testModelDefaultsMatchAndroidParity() {
        XCTAssertEqual(SamplerSettings.modelDefaults.accelerator, "cpu",
                       "GPU support is shipped (Metal xcframework embedded), but default is CPU because the iOS sim's Metal device hits a texture-binding limit on Gemma kernels. Real-device users opt into GPU via Settings.")
        XCTAssertEqual(SamplerSettings.modelDefaults.visionAccelerator, "")
        XCTAssertEqual(SamplerSettings.modelDefaults.audioAccelerator, "")
        XCTAssertEqual(SamplerSettings.modelDefaults.samplerType, 0)
        XCTAssertEqual(SamplerSettings.modelDefaults.seed, 0)
        XCTAssertEqual(SamplerSettings.modelDefaults.maxOutputTokens, 0)
        XCTAssertTrue(SamplerSettings.modelDefaults.applyPromptTemplate)
        XCTAssertFalse(SamplerSettings.modelDefaults.enableConstrainedDecoding)
        XCTAssertTrue(SamplerSettings.modelDefaults.parallelFileLoading)
        XCTAssertEqual(SamplerSettings.modelDefaults.activationDtype, -1)
        XCTAssertEqual(SamplerSettings.modelDefaults.prefillChunkSize, 0)
        XCTAssertFalse(SamplerSettings.modelDefaults.speculativeDecoding)
        XCTAssertEqual(SamplerSettings.modelDefaults.debugLogLevel, 1000,
                       "Silent log level by default — matches LiteRT-LM SILENT=1000")
    }

    func testCurrentReturnsModelDefaultsWhenUnset() {
        let keys = [
            SamplerSettings.acceleratorKey, SamplerSettings.visionAcceleratorKey,
            SamplerSettings.audioAcceleratorKey, SamplerSettings.samplerTypeKey,
            SamplerSettings.seedKey, SamplerSettings.maxOutputTokensKey,
            SamplerSettings.applyPromptTemplateKey, SamplerSettings.enableConstrainedDecodingKey,
            SamplerSettings.parallelFileLoadingKey, SamplerSettings.activationDtypeKey,
            SamplerSettings.prefillChunkSizeKey, SamplerSettings.speculativeDecodingKey,
            SamplerSettings.debugLogLevelKey,
        ]
        for k in keys { UserDefaults.standard.removeObject(forKey: k) }

        let snap = SamplerSettings.current()
        XCTAssertEqual(snap.accelerator, "cpu")
        XCTAssertEqual(snap.visionAccelerator, "")
        XCTAssertEqual(snap.audioAccelerator, "")
        XCTAssertEqual(snap.samplerType, 0)
        XCTAssertEqual(snap.seed, 0)
        XCTAssertEqual(snap.maxOutputTokens, 0)
        XCTAssertTrue(snap.applyPromptTemplate)
        XCTAssertFalse(snap.enableConstrainedDecoding)
        XCTAssertTrue(snap.parallelFileLoading)
        XCTAssertEqual(snap.activationDtype, -1)
        XCTAssertEqual(snap.prefillChunkSize, 0)
        XCTAssertFalse(snap.speculativeDecoding)
        XCTAssertEqual(snap.debugLogLevel, 1000)
    }

    func testCurrentRespectsModelKnobOverrides() {
        UserDefaults.standard.set("cpu", forKey: SamplerSettings.acceleratorKey)
        UserDefaults.standard.set("gpu", forKey: SamplerSettings.visionAcceleratorKey)
        UserDefaults.standard.set("cpu", forKey: SamplerSettings.audioAcceleratorKey)
        UserDefaults.standard.set(1, forKey: SamplerSettings.samplerTypeKey)
        UserDefaults.standard.set(42, forKey: SamplerSettings.seedKey)
        UserDefaults.standard.set(512, forKey: SamplerSettings.maxOutputTokensKey)
        UserDefaults.standard.set(false, forKey: SamplerSettings.applyPromptTemplateKey)
        UserDefaults.standard.set(true, forKey: SamplerSettings.enableConstrainedDecodingKey)
        UserDefaults.standard.set(false, forKey: SamplerSettings.parallelFileLoadingKey)
        UserDefaults.standard.set(1, forKey: SamplerSettings.activationDtypeKey)  // F16
        UserDefaults.standard.set(256, forKey: SamplerSettings.prefillChunkSizeKey)
        UserDefaults.standard.set(true, forKey: SamplerSettings.speculativeDecodingKey)
        UserDefaults.standard.set(0, forKey: SamplerSettings.debugLogLevelKey)    // verbose
        defer {
            for k in [
                SamplerSettings.acceleratorKey, SamplerSettings.visionAcceleratorKey,
                SamplerSettings.audioAcceleratorKey, SamplerSettings.samplerTypeKey,
                SamplerSettings.seedKey, SamplerSettings.maxOutputTokensKey,
                SamplerSettings.applyPromptTemplateKey, SamplerSettings.enableConstrainedDecodingKey,
                SamplerSettings.parallelFileLoadingKey, SamplerSettings.activationDtypeKey,
                SamplerSettings.prefillChunkSizeKey, SamplerSettings.speculativeDecodingKey,
                SamplerSettings.debugLogLevelKey,
            ] {
                UserDefaults.standard.removeObject(forKey: k)
            }
        }

        let snap = SamplerSettings.current()
        XCTAssertEqual(snap.accelerator, "cpu")
        XCTAssertEqual(snap.visionAccelerator, "gpu")
        XCTAssertEqual(snap.audioAccelerator, "cpu")
        XCTAssertEqual(snap.samplerType, 1)
        XCTAssertEqual(snap.seed, 42)
        XCTAssertEqual(snap.maxOutputTokens, 512)
        XCTAssertFalse(snap.applyPromptTemplate)
        XCTAssertTrue(snap.enableConstrainedDecoding)
        XCTAssertFalse(snap.parallelFileLoading)
        XCTAssertEqual(snap.activationDtype, 1)
        XCTAssertEqual(snap.prefillChunkSize, 256)
        XCTAssertTrue(snap.speculativeDecoding)
        XCTAssertEqual(snap.debugLogLevel, 0)
    }
}
