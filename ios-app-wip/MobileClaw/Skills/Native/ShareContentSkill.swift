import Foundation
import UIKit

// 1:1 functional port of android-app/assets/skills/share-content. Surfaces a
// UIActivityViewController so the user can share text. Requires UI thread
// + a presenting controller; we look it up from the active scene.

@MainActor public final class ShareContentSkill: Skill {
    nonisolated public var name: String { "share-content" }
    nonisolated public var description: String { "Open the system share sheet with text. arg: text" }
    public init() {}

    public func run(args: [String: String]) async -> ToolExecutionResult {
        let text = args["text"] ?? ""
        guard !text.isEmpty else {
            return ToolExecutionResult(success: false, error: "missing 'text' argument")
        }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.keyWindow?.rootViewController?.topMostViewController() else {
            return ToolExecutionResult(success: false, error: "no presenting view controller")
        }
        let vc = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            vc.completionWithItemsHandler = { _, _, _, _ in cont.resume() }
            root.present(vc, animated: true)
        }
        return ToolExecutionResult(success: true, output: "shared")
    }
}

private extension UIViewController {
    func topMostViewController() -> UIViewController {
        if let presented = presentedViewController { return presented.topMostViewController() }
        if let nav = self as? UINavigationController, let top = nav.visibleViewController { return top.topMostViewController() }
        if let tab = self as? UITabBarController, let sel = tab.selectedViewController { return sel.topMostViewController() }
        return self
    }
}
