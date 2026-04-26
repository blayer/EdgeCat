import Foundation
import AVFoundation

// 1:1 functional port of android-app/assets/skills/flashlight. Toggles the
// rear camera's torch. args: action=on|off|toggle.

public final class FlashlightSkill: Skill, @unchecked Sendable {
    public var name: String { "flashlight" }
    public var description: String { "Turn the flashlight on, off, or toggle. arg: action=on|off|toggle" }
    public init() {}

    public func run(args: [String: String]) async -> ToolExecutionResult {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else {
            return ToolExecutionResult(success: false, error: "no torch on this device")
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let action = args["action"] ?? "toggle"
            switch action {
            case "on":      device.torchMode = .on
            case "off":     device.torchMode = .off
            default:        device.torchMode = (device.torchMode == .on) ? .off : .on
            }
            return ToolExecutionResult(success: true, output: "torch: \(device.torchMode == .on ? "on" : "off")")
        } catch {
            return ToolExecutionResult(success: false, error: "\(error)")
        }
    }
}
