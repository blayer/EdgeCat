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
    /// True between `cancel()` and the next `start()`. URLSession fires
    /// `didCompleteWithError` with `NSURLErrorCancelled` after we cancel —
    /// we must ignore that callback so it doesn't overwrite the clean
    /// `.idle` state with a raw error string.
    private var cancelled: Bool = false

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
        cancelled = false
        status = .downloading(0)

        // Background config so the download survives the app being suspended
        // or the device locking. The URLSession needs a unique identifier per
        // session — re-using the same identifier across instances would
        // attach to an existing background task instead of starting fresh.
        let config = URLSessionConfiguration.background(
            withIdentifier: "com.edgecat.app.modelDownloader.\(model.id)")
        config.allowsCellularAccess = true
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: src)
        request.setValue("EdgeCat/0.1", forHTTPHeaderField: "User-Agent")
        // Attach HF user access token for gated models (Gemma 3n family etc.).
        if let token = HuggingFaceAuth.token() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let task = session.downloadTask(with: request)
        self.task = task
        task.resume()
    }

    public func cancel() {
        cancelled = true
        task?.cancel()
        task = nil
        bytesDownloaded = 0
        totalBytes = 0
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
            let message = Self.friendlyHttpMessage(code: code)
            Task { @MainActor in self.status = .failed(message) }
            return
        }
        do {
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: location, to: dst)
            Task { @MainActor in self.status = .succeeded(dst) }
        } catch {
            Task { @MainActor in
                self.status = .failed("Couldn't save the downloaded file. Please try again.")
            }
        }
    }

    nonisolated public func urlSession(_ session: URLSession,
                                       task: URLSessionTask,
                                       didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            // User-initiated cancellation: clean state, never expose
            // "Error Domain=NSURLErrorDomain Code=-999 …" to the UI.
            if self.cancelled || Self.isCancellationError(error) {
                self.status = .idle
                return
            }
            self.status = .failed(Self.friendlyTransportMessage(error))
        }
    }

    /// Whether an `Error` from URLSession represents user cancellation. We
    /// treat both `NSURLErrorCancelled` and Swift's `CancellationError` the
    /// same — they fire when the user taps Cancel mid-download, when
    /// `start()` is called twice, or when the app is force-quit.
    nonisolated private static func isCancellationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return true
        }
        if error is CancellationError { return true }
        return false
    }

    /// Translate non-2xx HTTP responses into messages a non-developer can
    /// act on. 401/403 are by far the most common — both mean the user
    /// needs to sign in to or accept terms on Hugging Face.
    nonisolated static func friendlyHttpMessage(code: Int) -> String {
        switch code {
        case 401:
            return "Sign in to Hugging Face to download this model."
        case 403:
            return "This model is gated. Accept its terms on huggingface.co, then try again."
        case 404:
            return "Model file not found. The URL in the catalog may be out of date."
        case 408, 504:
            return "Network timed out. Please try again."
        case 429:
            return "Hugging Face rate-limited the request. Please try again in a minute."
        case 500...599:
            return "Hugging Face is having trouble (HTTP \(code)). Please try again later."
        default:
            return "Download failed (HTTP \(code))."
        }
    }

    /// Translate transport-level errors (no DNS, no route, lost connection,
    /// SSL failure, etc.) into friendly messages. Falls back to a generic
    /// "Download failed" so we never leak the raw NSError description.
    nonisolated static func friendlyTransportMessage(_ error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return "Download failed. Please try again."
        }
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorDataNotAllowed:
            return "No internet connection. Reconnect and try again."
        case NSURLErrorTimedOut:
            return "Network timed out. Please try again."
        case NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed:
            return "Couldn't reach Hugging Face. Check your connection and try again."
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorClientCertificateRejected:
            return "Secure connection to Hugging Face failed. Please try again."
        default:
            return "Download failed. Please try again."
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
