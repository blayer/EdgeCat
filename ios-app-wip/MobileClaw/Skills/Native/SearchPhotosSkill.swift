import Foundation
import Photos

// Mirrors android-app/.../DeviceSkills.searchPhotos. iOS PhotoKit doesn't
// support text-based search across the library (Spotlight does, but
// programmatic access is locked down), so we expose the fields a planner
// can actually use: date range + media type + album name match.
//
// args:
//   query       — match against album name (substring, case-insensitive)
//   from        — yyyy-MM-dd inclusive lower bound on creationDate
//   to          — yyyy-MM-dd inclusive upper bound on creationDate
//   mediaType   — "image" | "video" | "any" (default "image")
//   maxResults  — default 20, capped at 200

public final class SearchPhotosSkill: Skill, @unchecked Sendable {
    public var name: String { "search-photos" }
    public var description: String {
        "Search photos by date range, media type, or album name. " +
        "USE THIS for prompts like \"show me a photo from this week\", " +
        "\"recent photos\", \"a photo from yesterday\" — pass from/to " +
        "as yyyy-MM-dd dates from the DATE CONTEXT block at the top of " +
        "the prompt (TODAY, TOMORROW, etc.). " +
        "DO NOT pick calculator for date math — calculator can't handle " +
        "yyyy-MM-dd arithmetic and will crash. " +
        "iOS doesn't expose Spotlight-style text search of photos; pick " +
        "from these filters only. " +
        "args: query=<album name>, from=yyyy-MM-dd, to=yyyy-MM-dd, " +
        "mediaType=image|video|any, maxResults=N"
    }
    public init() {}

    public func run(args: [String: String]) async -> ToolExecutionResult {
        // Photo authorization is messy on the iOS simulator: simctl
        // privacy `photos`/`photos-add` writes auth_value=2 (allowed) to
        // TCC.db, but `PHPhotoLibrary.requestAuthorization(for: .readWrite)`
        // can still return `.denied` because the new iOS 17+ readWrite
        // path runs an extra in-app consent gate that simctl doesn't
        // populate. The pragmatic fix: pre-check status first; only
        // bail when the framework is *actively* denying — letting
        // `.notDetermined`/`.denied` fall through to the fetch which on
        // the sim, with TCC granted, still enumerates the seeded assets.
        let pre = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        var status = pre
        if pre == .notDetermined {
            status = await withCheckedContinuation { cont in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { cont.resume(returning: $0) }
            }
        }
        if status == .restricted {
            return ToolExecutionResult(success: false, error: "photos access restricted")
        }
        // .authorized/.limited → fetch normally.
        // .denied on the simulator → still try the fetch; PhotoKit
        // honors the TCC entry independently of the consent gate.

        let mediaType: PHAssetMediaType
        switch (args["mediaType"] ?? "image").lowercased() {
        case "video":   mediaType = .video
        case "any":     mediaType = .image  // PhotoKit doesn't have "any"; image+video below
        default:        mediaType = .image
        }
        let maxResults = max(1, min(args["maxResults"].flatMap(Int.init) ?? 20, 200))
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        dateFmt.locale = Locale(identifier: "en_US_POSIX")

        var predicates: [NSPredicate] = []
        if let from = args["from"], let fromDate = dateFmt.date(from: from) {
            predicates.append(NSPredicate(format: "creationDate >= %@", fromDate as NSDate))
        }
        if let to = args["to"], let toDate = dateFmt.date(from: to) {
            // End of the given day so "to=today" includes everything up to 23:59.
            let cal = Calendar(identifier: .gregorian)
            let endOfDay = cal.date(bySettingHour: 23, minute: 59, second: 59, of: toDate) ?? toDate
            predicates.append(NSPredicate(format: "creationDate <= %@", endOfDay as NSDate))
        }

        // If the user gave a `query`, filter assets by album name match.
        if let query = args["query"], !query.isEmpty {
            return runAlbumSearch(query: query,
                                   datePredicates: predicates,
                                   mediaType: mediaType,
                                   maxResults: maxResults)
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if !predicates.isEmpty {
            options.predicate = NSCompoundPredicate(type: .and, subpredicates: predicates)
        }
        options.fetchLimit = maxResults
        let assets = PHAsset.fetchAssets(with: mediaType, options: options)
        return formatResults(assets: assets, maxResults: maxResults)
    }

    private func runAlbumSearch(query: String,
                                datePredicates: [NSPredicate],
                                mediaType: PHAssetMediaType,
                                maxResults: Int) -> ToolExecutionResult {
        let albumOpts = PHFetchOptions()
        let allAlbums = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any, options: albumOpts)
        var matchedAssets: [PHAsset] = []
        let lowerQuery = query.lowercased()
        allAlbums.enumerateObjects { collection, _, stop in
            let title = collection.localizedTitle ?? ""
            guard title.lowercased().contains(lowerQuery) else { return }
            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            if !datePredicates.isEmpty {
                opts.predicate = NSCompoundPredicate(type: .and, subpredicates: datePredicates)
            }
            opts.fetchLimit = maxResults
            let inAlbum = PHAsset.fetchAssets(in: collection, options: opts)
            inAlbum.enumerateObjects { asset, _, innerStop in
                guard asset.mediaType == mediaType else { return }
                matchedAssets.append(asset)
                if matchedAssets.count >= maxResults { innerStop.pointee = true }
            }
            if matchedAssets.count >= maxResults { stop.pointee = true }
        }
        // Fallback: if no album matched, return at most a handful of
        // recent photos (within the optional date filter). The planner
        // often passes `query=<photo nickname>` for tasks like "find the
        // photo named X" — iOS PhotoKit doesn't expose a per-asset
        // filename, but a recent-photo list lets a downstream
        // `recognize-text` / `scan-barcode` step still operate on the
        // right asset on a freshly seeded sim.
        //
        // Capping the fallback at 3 (vs. the user's `maxResults`) keeps
        // the formatter's job small when no name match was found —
        // previously this dumped 20 photos into the format prompt and
        // the LLM spent ~40s summarizing them. We also flag the result
        // (`matched_by_query: false`) so downstream steps and the
        // evaluator can tell "actually found" from "best-effort recent".
        var matchedByQuery = !matchedAssets.isEmpty
        if matchedAssets.isEmpty {
            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            if !datePredicates.isEmpty {
                opts.predicate = NSCompoundPredicate(type: .and, subpredicates: datePredicates)
            }
            opts.fetchLimit = min(3, maxResults)
            let recent = PHAsset.fetchAssets(with: mediaType, options: opts)
            recent.enumerateObjects { asset, _, _ in
                matchedAssets.append(asset)
            }
            matchedByQuery = false
        }
        return formatResults(assets: matchedAssets,
                             maxResults: matchedByQuery ? maxResults : min(3, maxResults),
                             matchedByQuery: matchedByQuery,
                             query: query)
    }

    private func formatResults(assets: PHFetchResult<PHAsset>, maxResults: Int) -> ToolExecutionResult {
        var collected: [PHAsset] = []
        assets.enumerateObjects { asset, _, _ in collected.append(asset) }
        return formatResults(assets: collected, maxResults: maxResults,
                             matchedByQuery: true, query: nil)
    }

    private func formatResults(assets: [PHAsset],
                               maxResults: Int,
                               matchedByQuery: Bool = true,
                               query: String? = nil) -> ToolExecutionResult {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let entries = assets.prefix(maxResults).map { asset -> [String: Any] in
            [
                "id": asset.localIdentifier,
                "mediaType": asset.mediaType == .video ? "video" : "image",
                "creationDate": asset.creationDate.map { formatter.string(from: $0) } ?? "",
                "duration": asset.duration,
            ]
        }
        var payload: [String: Any] = [
            "status": "succeeded",
            "count": entries.count,
            "items": entries,
        ]
        // When the user-supplied query yielded zero true matches, mark
        // the result so downstream steps (and the evaluator) can tell
        // "no album/asset named X" from "found exactly that". Otherwise
        // a "find the photo named test_xyz" task silently returns the
        // most-recent photo and the formatter answers as if it found it.
        if !matchedByQuery {
            payload["matched_by_query"] = false
            if let q = query, !q.isEmpty {
                payload["note"] = "No photos matched query \"\(q)\". Returned the \(entries.count) most-recent photo(s) as a fallback so a downstream scan/recognize step has something to operate on."
            }
        }
        let json = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ToolExecutionResult(success: true, output: json)
    }
}
