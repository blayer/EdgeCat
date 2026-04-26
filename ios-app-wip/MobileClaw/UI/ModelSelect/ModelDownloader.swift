import Foundation
import Observation

// 1:1 functional port of android-app/.../ui/modelmanager/ModelManagerViewModel.kt's
// download surface — URLSession-based, with bytesDownloaded / progress /
// status published as observable state. Uses a background URLSessionConfiguration
// so multi-GB Gemma 4 E4B downloads survive app suspension / lock screen.

@MainActor
@Observable
public final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    public enum Status: Equatable {
        case idle, downloading(Double), succeeded(URL), failed(String)
    }

    public private(set) var status: Status = .idle
    public private(set) var bytesDownloaded: Int64 = 0
    public private(set) var totalBytes: Int64 = 0

    private var task: URLSessionDownloadTask?
    private var destination: URL?

    public override init() { super.init() }

    public func start(model: CatalogModel) {
        guard let src = model.downloadURL else {
            status = .failed("invalid download URL")
            return
        }
        let dir: URL
        do {
            dir = try Self.modelsDirectory()
        } catch {
            status = .failed("unable to access Models directory: \(error.localizedDescription)")
            return
        }
        let dest = dir.appendingPathComponent(model.modelFile)
        if FileManager.default.fileExists(atPath: dest.path) {
            status = .succeeded(dest)
            return
        }
        destination = dest
        totalBytes = model.sizeInBytes
        bytesDownloaded = 0
        status = .downloading(0)

        // Background config so the download survives the app being suspended
        // or the device locking. The URLSession needs a unique identifier per
        // session — re-using the same identifier across instances would
        // attach to an existing background task instead of starting fresh.
        let config = URLSessionConfiguration.background(
            withIdentifier: "com.mobileclawapp.app.modelDownloader.\(model.id)")
        config.allowsCellularAccess = true
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: src)
        request.setValue("Mobile-Claw/0.1", forHTTPHeaderField: "User-Agent")
        // Attach HF user access token for gated models (Gemma 3n family etc.).
        if let token = HuggingFaceAuth.token() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let task = session.downloadTask(with: request)
        self.task = task
        task.resume()
    }

    public func cancel() {
        task?.cancel()
        task = nil
        status = .idle
    }

    // MARK: URLSessionDownloadDelegate
    nonisolated public func urlSession(_ session: URLSession,
                                       downloadTask: URLSessionDownloadTask,
                                       didWriteData bytesWritten: Int64,
                                       totalBytesWritten: Int64,
                                       totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : self.totalBytes
            let progress = total > 0 ? Double(totalBytesWritten) / Double(total) : 0
            self.bytesDownloaded = totalBytesWritten
            self.totalBytes = total
            self.status = .downloading(progress)
        }
    }

    nonisolated public func urlSession(_ session: URLSession,
                                       downloadTask: URLSessionDownloadTask,
                                       didFinishDownloadingTo location: URL) {
        // The temp file at `location` is deleted by URLSession when this call
        // returns, so we must move synchronously before hopping back to main.
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
        let dst: URL
        do {
            dst = try Self.modelsDirectory()
                .appendingPathComponent(downloadTask.originalRequest?.url?.lastPathComponent ?? "downloaded.litertlm")
        } catch {
            try? FileManager.default.removeItem(at: location)
            Task { @MainActor in self.status = .failed("unable to access Models directory: \(error.localizedDescription)") }
            return
        }
        if !(200..<400).contains(code) {
            try? FileManager.default.removeItem(at: location)
            Task { @MainActor in self.status = .failed("HTTP \(code) — model may be HF-gated") }
            return
        }
        do {
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: location, to: dst)
            Task { @MainActor in self.status = .succeeded(dst) }
        } catch {
            Task { @MainActor in self.status = .failed("\(error)") }
        }
    }

    nonisolated public func urlSession(_ session: URLSession,
                                       task: URLSessionTask,
                                       didCompleteWithError error: Error?) {
        if let error {
            Task { @MainActor in self.status = .failed("\(error)") }
        }
    }

    // `nonisolated` because the URLSessionDownloadDelegate callbacks above are
    // `nonisolated` (they fire from URLSession's background thread) and need
    // to compute the destination synchronously before the temp file at
    // `location` is reaped by URLSession on return. Pure FileManager work is
    // thread-safe; no main-actor state is touched.
    nonisolated private static func modelsDirectory(fileManager: FileManager = .default) throws -> URL {
        let docs = try fileManager.url(for: .documentDirectory,
                                       in: .userDomainMask,
                                       appropriateFor: nil,
                                       create: true)
        let dir = docs.appendingPathComponent("Models", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
