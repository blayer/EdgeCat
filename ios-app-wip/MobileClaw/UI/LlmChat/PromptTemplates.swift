import Foundation

// 1:1 port of android-app/.../assets/prompt_templates.json (or its inline
// equivalent) — starter prompts shown in the empty-chat state. Tap fills the
// input field; user can edit before sending.

public enum PromptTemplates {
    public static func load() -> [String] {
        guard let url = Bundle.main.url(forResource: "prompt_templates", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let arr = dict["templates"] as? [String] else {
            return []
        }
        return arr
    }
}
