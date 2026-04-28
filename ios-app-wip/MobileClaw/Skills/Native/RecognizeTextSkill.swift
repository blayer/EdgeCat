import Foundation
import Vision
import UIKit
import Photos

// On-device text recognition (Live Text / OCR) via the Vision framework.
// iOS-platform-unique: Android Vision Text Recognizer requires GMS Play
// Services and a model download; iOS bundles this for free with deep
// language packs. Runs entirely on-device — no network, no usage cost.
//
// args:
//   path        — absolute file path to a PNG/JPEG on disk. Mutually
//                 exclusive with photo_id.
//   photo_id    — PHAsset.localIdentifier from `search-photos`. Required
//                 if `path` is absent. Triggers the photo-library
//                 permission gate.
//   languages   — comma-separated BCP-47 codes (default: "en-US")
//
// Output JSON: { status, text, confidence_avg, language, observation_count }

public final class RecognizeTextSkill: Skill, @unchecked Sendable {
    public var name: String { "recognize-text" }
    public var description: String {
        "Extract text from an image using on-device OCR (Live Text). " +
        "args: path=<file path> OR photo_id=<PHAsset localIdentifier>, " +
        "languages=<en-US,fr-FR,...> (default en-US)"
    }
    public init() {}

    public func run(args: [String: String]) async -> ToolExecutionResult {
        let languages = (args["languages"] ?? "en-US")
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let cgImage: CGImage
        if let path = args["path"], !path.isEmpty {
            guard let img = UIImage(contentsOfFile: path),
                  let cg = img.cgImage else {
                return ToolExecutionResult(success: false,
                                            error: "couldn't load image at: \(path)")
            }
            cgImage = cg
        } else if let photoId = args["photo_id"], !photoId.isEmpty {
            do {
                cgImage = try await loadAssetCGImage(photoId: photoId)
            } catch {
                return ToolExecutionResult(success: false,
                                            error: "couldn't load asset: \(error.localizedDescription)")
            }
        } else {
            return ToolExecutionResult(success: false,
                                        error: "missing 'path' or 'photo_id' argument")
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if !languages.isEmpty { request.recognitionLanguages = languages }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ToolExecutionResult(success: false,
                                        error: "vision request failed: \(error.localizedDescription)")
        }
        let observations = request.results ?? []
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n")
        let confidences = observations.compactMap { $0.topCandidates(1).first?.confidence }
        let avgConfidence = confidences.isEmpty ? 0.0
            : confidences.reduce(0.0, +) / Float(confidences.count)

        let payload: [String: Any] = [
            "status": "succeeded",
            "text": text,
            "confidence_avg": avgConfidence,
            "language": languages.first ?? "en-US",
            "observation_count": observations.count,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: []))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ToolExecutionResult(success: true, output: json)
    }

    /// Fetch a `CGImage` for a `PHAsset.localIdentifier`. Requests
    /// photo-library access on first call; the system remembers the
    /// answer for subsequent skill invocations.
    private func loadAssetCGImage(photoId: String) async throws -> CGImage {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "RecognizeTextSkill", code: 401,
                           userInfo: [NSLocalizedDescriptionKey: "photos access denied"])
        }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [photoId], options: nil)
        guard let asset = result.firstObject else {
            throw NSError(domain: "RecognizeTextSkill", code: 404,
                           userInfo: [NSLocalizedDescriptionKey: "no asset with id \(photoId)"])
        }
        let manager = PHImageManager.default()
        let opts = PHImageRequestOptions()
        opts.isSynchronous = false
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CGImage, Error>) in
            // Pixel-size cap so a 48 MP HEIC doesn't blow up Vision's
            // peak memory. Vision's rec'd minimum is ~150 px tall.
            let target = CGSize(width: 4096, height: 4096)
            manager.requestImage(for: asset, targetSize: target,
                                  contentMode: .aspectFit,
                                  options: opts) { image, info in
                if let err = info?[PHImageErrorKey] as? Error {
                    cont.resume(throwing: err); return
                }
                guard let cg = image?.cgImage else {
                    cont.resume(throwing: NSError(domain: "RecognizeTextSkill", code: 500,
                                                    userInfo: [NSLocalizedDescriptionKey: "no CGImage from asset"]))
                    return
                }
                cont.resume(returning: cg)
            }
        }
    }
}
