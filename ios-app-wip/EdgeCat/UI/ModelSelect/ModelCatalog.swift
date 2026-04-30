import Foundation

// Loads the bundled model_allowlist.json — same shape as
// android-app/model_allowlists/*.json. A future enhancement is to also
// fetch the latest version from upstream GitHub raw, but Phase B uses
// the bundled copy for offline-first.

public enum ModelCatalog {
    public static func load() -> [CatalogModel] {
        guard let url = Bundle.main.url(forResource: "model_allowlist", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return []
        }
        do {
            return try JSONDecoder().decode(CatalogResponse.self, from: data).models
        } catch {
            print("[ModelCatalog] decode failed: \(error)")
            return []
        }
    }
}
