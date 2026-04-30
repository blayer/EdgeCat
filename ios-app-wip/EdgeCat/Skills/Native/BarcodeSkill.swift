import Foundation
import UIKit
import Vision
import VisionKit
import Photos
import CoreImage

// 1:1 functional port of android-app/assets/skills/scan-barcode. Two
// modes:
//   - Live camera scan (default): VisionKit's DataScannerViewController.
//   - Photo-library scan: when `path` or `photo_id` is provided, uses
//     `VNDetectBarcodesRequest` against the saved asset. Lets the
//     planner chain `search-photos → scan-barcode` without a camera UI,
//     which is also how the eval harness drives the skill headlessly.

@MainActor
public final class BarcodeSkill: Skill {
    nonisolated public var name: String { "scan-barcode" }
    nonisolated public var description: String {
        "Scan a barcode or QR and return its decoded text. " +
        "Default: opens the camera live. " +
        "Pass `path=<file>` or `photo_id=<PHAsset id>` to scan an existing " +
        "image from the user's photo library — useful when the user says " +
        "'find the photo named X and scan it'. " +
        "args: path=<optional> photo_id=<optional>"
    }
    public init() {}

    public func run(args: [String: String]) async -> ToolExecutionResult {
        // Photo-library mode: bypass the camera UI when an image source
        // is named explicitly or passed through from `search-photos`.
        // Either arg may carry the JSON envelope verbatim if the
        // planner chained `"Output from s1"` — try both. When the JSON
        // lists multiple asset ids (search-photos returns up to 20),
        // walk the list until we hit a barcode — the asset the planner
        // really wants might not be the most-recent one.
        let pathArg = args["path"] ?? ""
        let photoIdArg = args["photo_id"] ?? ""
        let allIds = RecognizeTextSkill.extractAllImageIds(from: pathArg)
            + RecognizeTextSkill.extractAllImageIds(from: photoIdArg)
        if !allIds.isEmpty {
            return await scanFromLibraryMany(photoIds: allIds)
        }
        if !pathArg.isEmpty || !photoIdArg.isEmpty {
            return await scanFromLibrary(path: pathArg, photoId: photoIdArg)
        }

        guard DataScannerViewController.isSupported,
              DataScannerViewController.isAvailable else {
            return ToolExecutionResult(success: false,
                                       error: "barcode scanning not available on this device")
        }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.keyWindow?.rootViewController else {
            return ToolExecutionResult(success: false, error: "no presenting view controller")
        }

        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode()],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true)

        return await withCheckedContinuation { (cont: CheckedContinuation<ToolExecutionResult, Never>) in
            let delegate = ScannerDelegate { result in
                cont.resume(returning: result)
                scanner.dismiss(animated: true)
            }
            scanner.delegate = delegate
            // Hold the delegate strongly until the scanner dismisses.
            objc_setAssociatedObject(scanner, &delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)
            root.present(scanner, animated: true) {
                try? scanner.startScanning()
            }
        }
    }

    /// Detect barcodes / QR codes in a stored image (file path or
    /// PHAsset). Uses Vision's `VNDetectBarcodesRequest` — same engine
    /// the camera scanner uses, just fed a still image. Returns the
    /// first recognized payload (single-item by default; we don't
    /// expect a planner-driven scan to surface multiples).
    /// Walk a list of candidate `PHAsset` ids until one yields a
    /// barcode. Used when the planner chains `search-photos →
    /// scan-barcode` and the upstream returns multiple matches; the
    /// asset we actually want isn't always the most-recent one.
    private func scanFromLibraryMany(photoIds: [String]) async -> ToolExecutionResult {
        var lastError = "no barcode found in any of \(photoIds.count) image(s)"
        for id in photoIds {
            let result = await scanFromLibrary(path: "", photoId: id)
            if result.success { return result }
            if let err = result.error, !err.isEmpty { lastError = err }
        }
        return ToolExecutionResult(success: false, error: lastError)
    }

    private func scanFromLibrary(path: String, photoId: String) async -> ToolExecutionResult {
        let cgImage: CGImage
        if !path.isEmpty {
            guard let img = UIImage(contentsOfFile: path), let cg = img.cgImage else {
                return ToolExecutionResult(success: false,
                                           error: "couldn't load image at: \(path)")
            }
            cgImage = cg
        } else if Self.looksLikePhotoAssetId(photoId) {
            do {
                cgImage = try await Self.loadAssetCGImage(photoId: photoId)
            } catch {
                return ToolExecutionResult(success: false,
                                           error: "couldn't load asset: \(error.localizedDescription)")
            }
        } else {
            // Planner sometimes hallucinates a "name-style" id like
            // `"PHAsset test_qr_claude"` for a prompt that says "the
            // photo named X". Treat it as a request to scan ALL recent
            // photos until we find a barcode — same fallback path
            // `scanFromLibraryMany` uses for chained search-photos
            // results.
            return await scanRecentLibrary(maxAssets: 30)
        }
        // Try Vision first (best on real devices). On the iOS sim
        // VNDetectBarcodesRequest can fail with "Could not create
        // inference context" because Vision's neural backends aren't
        // wired up — fall back to the older `CIDetector(type:.QRCode)`,
        // which is software-only and works headlessly.
        let visionPayload = Self.detectViaVision(cgImage: cgImage)
        if let payload = visionPayload, !payload.isEmpty {
            return ToolExecutionResult(success: true, output: payload)
        }
        if let payload = Self.detectViaCoreImage(cgImage: cgImage), !payload.isEmpty {
            return ToolExecutionResult(success: true, output: payload)
        }
        return ToolExecutionResult(success: false,
                                   error: "no barcode found in image")
    }

    private static func detectViaVision(cgImage: CGImage) -> String? {
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        let observations = (request.results as? [VNBarcodeObservation]) ?? []
        return observations.first?.payloadStringValue
    }

    private static func detectViaCoreImage(cgImage: CGImage) -> String? {
        let ciImage = CIImage(cgImage: cgImage)
        let context = CIContext(options: nil)
        let detector = CIDetector(ofType: CIDetectorTypeQRCode,
                                   context: context,
                                   options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: ciImage) ?? []
        for f in features {
            if let qr = f as? CIQRCodeFeature, let m = qr.messageString, !m.isEmpty {
                return m
            }
        }
        return nil
    }

    /// `PHAsset.localIdentifier` is `"UUID/L0/001"` — anything without
    /// that shape is a planner hallucination (e.g. `"PHAsset
    /// test_qr_claude"`) and we shouldn't bother PHFetchAssets with it.
    private static func looksLikePhotoAssetId(_ s: String) -> Bool {
        s.count >= 36 && s.contains("-") && s.contains("/")
    }

    /// Walk the user's most-recent N image assets looking for a
    /// barcode. Used when the planner asked for a barcode scan but
    /// gave us no concrete asset id — better than failing outright.
    private func scanRecentLibrary(maxAssets: Int) async -> ToolExecutionResult {
        let pre = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        var status = pre
        if pre == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        if status == .restricted {
            return ToolExecutionResult(success: false, error: "photos access restricted")
        }
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.fetchLimit = max(1, min(maxAssets, 100))
        let assets = PHAsset.fetchAssets(with: .image, options: opts)
        var ids: [String] = []
        assets.enumerateObjects { a, _, _ in ids.append(a.localIdentifier) }
        if ids.isEmpty {
            return ToolExecutionResult(success: false, error: "no photos in library")
        }
        return await scanFromLibraryMany(photoIds: ids)
    }

    private static func loadAssetCGImage(photoId: String) async throws -> CGImage {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "BarcodeSkill", code: 401,
                           userInfo: [NSLocalizedDescriptionKey: "photos access denied"])
        }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [photoId], options: nil)
        guard let asset = result.firstObject else {
            throw NSError(domain: "BarcodeSkill", code: 404,
                           userInfo: [NSLocalizedDescriptionKey: "no asset with id \(photoId)"])
        }
        let manager = PHImageManager.default()
        let opts = PHImageRequestOptions()
        opts.isSynchronous = false
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CGImage, Error>) in
            let target = CGSize(width: 4096, height: 4096)
            manager.requestImage(for: asset, targetSize: target,
                                  contentMode: .aspectFit, options: opts) { image, info in
                if let err = info?[PHImageErrorKey] as? Error {
                    cont.resume(throwing: err); return
                }
                guard let cg = image?.cgImage else {
                    cont.resume(throwing: NSError(domain: "BarcodeSkill", code: 500,
                                                   userInfo: [NSLocalizedDescriptionKey: "no CGImage from asset"]))
                    return
                }
                cont.resume(returning: cg)
            }
        }
    }
}

private var delegateKey: UInt8 = 0

private final class ScannerDelegate: NSObject, DataScannerViewControllerDelegate {
    let onResult: (ToolExecutionResult) -> Void
    init(onResult: @escaping (ToolExecutionResult) -> Void) { self.onResult = onResult }

    func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
        switch item {
        case let .barcode(b):
            onResult(.init(success: true, output: b.payloadStringValue ?? ""))
        default:
            onResult(.init(success: false, error: "unrecognized item"))
        }
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                     allItems: [RecognizedItem]) {
        // Auto-emit the first recognized item without requiring a tap.
        if case let .barcode(b) = addedItems.first {
            onResult(.init(success: true, output: b.payloadStringValue ?? ""))
        }
    }
}
