import Foundation
import UIKit

// 1:1 functional port of android-app/assets/skills/device-info. Returns a
// stable JSON string with iOS-equivalent fields (name, system, model,
// memory, storage).

@MainActor public final class DeviceInfoSkill: Skill {
    nonisolated public var name: String { "device-info" }
    nonisolated public var description: String { "Return JSON with device name, OS, model, memory, free storage." }
    public init() {}

    public func run(args: [String: String]) async -> ToolExecutionResult {
        let device = UIDevice.current
        let info = ProcessInfo.processInfo
        let bytes = info.physicalMemory
        let storage = (try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()))
            .flatMap { $0[.systemFreeSize] as? Int64 } ?? 0
        let json: [String: Any] = [
            "name": device.name,
            "system": "\(device.systemName) \(device.systemVersion)",
            "model": device.model,
            "memory_mb": bytes / 1_048_576,
            "free_storage_mb": storage / 1_048_576,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])) ?? Data()
        let str = String(data: data, encoding: .utf8) ?? "{}"
        return ToolExecutionResult(success: true, output: str)
    }
}
