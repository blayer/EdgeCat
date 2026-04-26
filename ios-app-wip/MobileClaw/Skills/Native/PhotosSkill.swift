import Foundation
import Photos

// 1:1 functional port of android-app/assets/skills/list-photos. Returns
// counts and recent dates from PhotoKit. PhotoKit auth is permission-gated.

public final class PhotosSkill: Skill, @unchecked Sendable {
    public var name: String { "list-photos" }
    public var description: String { "Summarize the user's photo library: total count + recent dates." }
    public init() {}

    public func run(args: [String: String]) async -> ToolExecutionResult {
        let status: PHAuthorizationStatus = await withCheckedContinuation { cont in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { cont.resume(returning: $0) }
        }
        guard status == .authorized || status == .limited else {
            return ToolExecutionResult(success: false, error: "photos access denied")
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 5
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        let total = PHAsset.fetchAssets(with: .image, options: PHFetchOptions()).count
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        var dates: [String] = []
        assets.enumerateObjects { asset, _, _ in
            if let d = asset.creationDate { dates.append(formatter.string(from: d)) }
        }
        let recent = dates.isEmpty ? "" : "Recent: " + dates.joined(separator: ", ")
        return ToolExecutionResult(success: true, output: "Total photos: \(total). \(recent)")
    }
}
