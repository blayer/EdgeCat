import Foundation
import UIKit
import VisionKit

// 1:1 functional port of android-app/assets/skills/scan-barcode. iOS uses
// VisionKit's DataScannerViewController (iOS 16+), which presents a live
// camera scanner that returns recognized items. We surface the first
// recognized barcode/QR text as the skill's output.

@MainActor
public final class BarcodeSkill: Skill {
    nonisolated public var name: String { "scan-barcode" }
    nonisolated public var description: String {
        "Open the camera to scan a barcode or QR and return its decoded text."
    }
    public init() {}

    public func run(args: [String: String]) async -> ToolExecutionResult {
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
