import Foundation
import Network

// 1:1 port of android-app/.../orchestration/ConnectivityChecker.kt — uses
// NWPathMonitor which is the iOS equivalent of ConnectivityManager.

public enum ConnectivityChecker {
    /// Skills that require internet access. Excluded from planning when offline.
    public static let internetSkills: Set<String> = [
        "search-web", "fetch-web-content", "open-url", "send-email",
    ]

    /// Returns true if the device has a validated internet connection.
    /// Snapshots the current path; for live observation use a long-lived NWPathMonitor.
    public static func isOnline() -> Bool {
        let monitor = NWPathMonitor()
        let semaphore = DispatchSemaphore(value: 0)
        var status: NWPath.Status = .unsatisfied
        monitor.pathUpdateHandler = { path in
            status = path.status
            semaphore.signal()
            monitor.cancel()
        }
        monitor.start(queue: DispatchQueue(label: "com.mobileclaw.connectivity"))
        _ = semaphore.wait(timeout: .now() + .milliseconds(200))
        return status == .satisfied
    }
}
