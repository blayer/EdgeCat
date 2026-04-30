import Foundation
import UIKit

// 1:1 functional port of android-app/assets/skills/phone-call. Opens the
// system tel: URL — iOS shows the user a confirmation; we can't dial without
// it. Returns success on URL open.

@MainActor public final class PhoneCallSkill: Skill {
    nonisolated public var name: String { "phone-call" }
    nonisolated public var description: String { "Place a phone call (user-confirmed). arg: number" }
    public init() {}

    public func run(args: [String: String]) async -> ToolExecutionResult {
        guard let number = args["number"], !number.isEmpty else {
            return ToolExecutionResult(success: false, error: "missing 'number' argument")
        }
        let stripped = number.filter { "0123456789+".contains($0) }
        guard let url = URL(string: "tel://\(stripped)") else {
            return ToolExecutionResult(success: false, error: "invalid number")
        }
        let opened = await UIApplication.shared.open(url)
        return ToolExecutionResult(success: opened, output: opened ? "opened tel: \(stripped)" : "could not open")
    }
}
