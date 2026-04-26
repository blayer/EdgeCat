import Foundation

// 1:1 port of android-app/.../data/AllowedModel.kt — the JSON shape from
// model_allowlists/*.json. Fields the Android allowlist uses but iOS
// doesn't act on yet (commitHash, accelerators, etc.) are decoded for
// faithfulness; we'll surface them in the UI in later phases.

public struct CatalogModel: Codable, Identifiable, Hashable {
    public let name: String
    public let modelId: String
    public let modelFile: String
    public let description: String
    public let sizeInBytes: Int64
    public let minDeviceMemoryInGb: Int?
    public let commitHash: String?
    public let llmSupportImage: Bool?
    public let llmSupportAudio: Bool?
    public let llmSupportThinking: Bool?
    public let defaultConfig: DefaultConfig?
    public let taskTypes: [String]?
    public let bestForTaskTypes: [String]?
    public let needsAuth: Bool?

    public var id: String { modelId + "/" + modelFile }

    /// HuggingFace URL the file lives at. Mirrors Android's resolve logic.
    public var downloadURL: URL? {
        guard let escaped = modelFile.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://huggingface.co/\(modelId)/resolve/main/\(escaped)")
    }

    public struct DefaultConfig: Codable, Hashable {
        public let topK: Int?
        public let topP: Double?
        public let temperature: Double?
        public let maxContextLength: Int?
        public let maxTokens: Int?
        public let accelerators: String?
        public let visionAccelerator: String?
    }
}

public struct CatalogResponse: Codable {
    public let models: [CatalogModel]
}
