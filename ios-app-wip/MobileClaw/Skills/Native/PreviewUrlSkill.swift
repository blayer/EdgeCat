import Foundation
import LinkPresentation

// LinkPresentation rich URL preview. iOS-platform-unique: macOS / iOS
// system extracts Open Graph + Twitter card metadata from any URL via
// the same engine Messages.app and Notes.app use. Android has no
// equivalent system API — apps roll their own with HTML scrapers.
//
// args:
//   url    — required, http(s) URL to fetch metadata for
//   timeout_s — optional, default 10, max 30 (LP can hang on slow sites)
//
// Output JSON: { status, url, title, description, image_url, icon_url,
//                provider }
//
// Note: iOS treats `LPMetadataProvider` as one-shot — a fresh provider
// per fetch. The provider is `Sendable` but its callback is not, which
// is why the dispatch hops back to MainActor for the continuation.

public final class PreviewUrlSkill: Skill, @unchecked Sendable {
    public var name: String { "preview-url" }
    public var description: String {
        "Use this for any 'title / preview / what is at this URL' question. " +
        "Returns the page title, description, and preview image URL (Open " +
        "Graph + Twitter card metadata) using the same engine iMessage and " +
        "Notes use to render link previews. " +
        "PREFER this over fetch-web-content + an extraction step when the " +
        "user just wants the title or summary of a URL. " +
        "Works for any http(s) URL — GitHub repos, news articles, blog posts. " +
        "args: url=<http(s) URL>, timeout_s=<N, default 10>"
    }
    public init() {}

    public func run(args: [String: String]) async -> ToolExecutionResult {
        guard let raw = args["url"], !raw.isEmpty else {
            return ToolExecutionResult(success: false, error: "missing 'url' argument")
        }
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return ToolExecutionResult(success: false,
                                        error: "url must be http(s): \(raw)")
        }
        let timeout = max(1, min(args["timeout_s"].flatMap(Int.init) ?? 10, 30))
        let provider = LPMetadataProvider()
        provider.timeout = TimeInterval(timeout)

        do {
            let metadata = try await provider.startFetchingMetadata(for: url)
            let imageUrl = await imageItemProviderURL(metadata.imageProvider)
            let iconUrl = await imageItemProviderURL(metadata.iconProvider)
            let payload: [String: Any] = [
                "status": "succeeded",
                "url": metadata.url?.absoluteString ?? raw,
                "title": metadata.title ?? "",
                "image_url": imageUrl ?? "",
                "icon_url": iconUrl ?? "",
                // `LPLinkMetadata` doesn't expose a direct description field
                // — the system caches what the user-visible card shows
                // (which is sometimes title-only). Keep the key for
                // schema stability with Android-style outputs.
                "description": "",
            ]
            let json = (try? JSONSerialization.data(withJSONObject: payload, options: []))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return ToolExecutionResult(success: true, output: json)
        } catch {
            return ToolExecutionResult(success: false,
                                        error: "couldn't fetch metadata: \(error.localizedDescription)")
        }
    }

    /// `NSItemProvider` carries the image lazily — best-effort
    /// extract a URL representation if the provider has one.
    /// Returns nil quietly if the provider doesn't expose a URL form;
    /// the planner still gets `image_url: ""` which is honest.
    private func imageItemProviderURL(_ provider: NSItemProvider?) async -> String? {
        guard let provider else { return nil }
        let typeIdentifier = "public.url"
        guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else {
            return nil
        }
        return try? await withCheckedThrowingContinuation { (cont: CheckedContinuation<String?, Error>) in
            provider.loadItem(forTypeIdentifier: typeIdentifier) { item, err in
                if let err { cont.resume(throwing: err); return }
                if let url = item as? URL { cont.resume(returning: url.absoluteString) }
                else if let data = item as? Data,
                        let str = String(data: data, encoding: .utf8) { cont.resume(returning: str) }
                else { cont.resume(returning: nil) }
            }
        }
    }
}
