import Foundation
import Observation
import UniformTypeIdentifiers

// 1:1 functional port of android-app/.../ui/modelmanager/ModelImportDialog.kt
// (Kotlin) — copies a user-picked .litertlm file from a security-scoped
// `URL` (e.g. Files / iCloud Drive / On My iPhone) into the app's
// Documents/Models/ folder, streaming the bytes so the UI can show a live
// progress bar without holding the entire 4 GB blob in memory at once.

/// `.litertlm` UTI. The model files don't have a system-registered type,
/// so we declare one here and let the file importer accept it.
extension UTType {
    static var litertlm: UTType {
        // The file-extension fallback resolves at runtime — picks any
        // existing UTI matching `.litertlm`, otherwise synthesizes a fresh
        // one named `dyn.<encoded>` so the picker still surfaces matching
        // files. Both branches accept the same extension.
        UTType(filenameExtension: "litertlm") ?? UTType.data
    }
}

@MainActor
@Observable
public final class LitertlmImporter {
    public enum Status: Equatable {
        case idle
        case copying(Double)        // progress 0..1
        case succeeded(URL)
        case failed(String)
    }

    public private(set) var status: Status = .idle
    public private(set) var bytesCopied: Int64 = 0
    public private(set) var totalBytes: Int64 = 0

    public init() {}

    /// Copy the user-picked source URL into Documents/Models/. The source
    /// must be a security-scoped URL (the kind SwiftUI's `.fileImporter`
    /// hands you in its callback); `start(...)` calls
    /// `startAccessingSecurityScopedResource()` on the caller's behalf.
    public func start(from source: URL) {
        status = .copying(0)
        bytesCopied = 0
        totalBytes = 0
        Task.detached { [weak self] in
            await self?.runCopy(source: source)
        }
    }

    public func reset() {
        status = .idle
        bytesCopied = 0
        totalBytes = 0
    }

    // MARK: - Internals

    private func runCopy(source: URL) async {
        let started = source.startAccessingSecurityScopedResource()
        defer { if started { source.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let destination: URL
        do {
            let docs = try fm.url(for: .documentDirectory, in: .userDomainMask,
                                   appropriateFor: nil, create: true)
            let dir = docs.appendingPathComponent("Models", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            destination = dir.appendingPathComponent(source.lastPathComponent)
        } catch {
            await MainActor.run {
                self.status = .failed("Couldn't open Models directory: \(error.localizedDescription)")
            }
            return
        }

        // If the target already exists, refuse rather than overwrite. The
        // user can swipe-delete the old one and retry.
        if fm.fileExists(atPath: destination.path) {
            await MainActor.run {
                self.status = .failed("\(destination.lastPathComponent) already exists in Models/. Delete it first.")
            }
            return
        }

        do {
            let total = try Self.fileSize(at: source)
            await MainActor.run { self.totalBytes = total }
            try Self.streamCopy(source: source, destination: destination,
                                totalBytes: total) { copied in
                Task { @MainActor in
                    self.bytesCopied = copied
                    let progress = total > 0 ? Double(copied) / Double(total) : 0
                    self.status = .copying(progress)
                }
            }
            await MainActor.run {
                self.status = .succeeded(destination)
            }
        } catch {
            // Clean up a partial copy so the next attempt starts clean.
            try? fm.removeItem(at: destination)
            await MainActor.run {
                self.status = .failed("Import failed: \(error.localizedDescription)")
            }
        }
    }

    /// `URLResourceValues.fileSize` is the closest portable equivalent to
    /// Android's `OpenableColumns.SIZE` query.
    private static func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    /// Stream-copy with progress callback. We chunk at 4 MB so even a
    /// 4 GB Gemma 4 E4B file can be moved without memory pressure on
    /// constrained devices. `nonisolated` because the function only does
    /// pure file I/O — no actor-isolated state — and the caller (the
    /// detached Task in `runCopy`) is off the main actor anyway.
    nonisolated static func streamCopy(source: URL, destination: URL,
                                       totalBytes: Int64,
                                       chunkSize: Int = 4 * 1024 * 1024,
                                       onProgress: @Sendable (Int64) -> Void) throws {
        let fm = FileManager.default
        if !fm.createFile(atPath: destination.path, contents: nil) {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                          userInfo: [NSLocalizedDescriptionKey:
                                       "Couldn't create \(destination.lastPathComponent)"])
        }
        let inHandle = try FileHandle(forReadingFrom: source)
        let outHandle = try FileHandle(forWritingTo: destination)
        defer { try? inHandle.close(); try? outHandle.close() }

        var copied: Int64 = 0
        while true {
            let data = try inHandle.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { break }
            try outHandle.write(contentsOf: data)
            copied += Int64(data.count)
            onProgress(copied)
        }
    }
}
