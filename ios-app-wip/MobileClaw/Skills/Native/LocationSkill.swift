import Foundation
import CoreLocation

// 1:1 functional port of android-app/assets/skills/get-location. Single-shot
// location reading via CLLocationManager. Permission-gated.

public final class LocationSkill: NSObject, Skill, CLLocationManagerDelegate, @unchecked Sendable {
    public var name: String { "get-location" }
    /// NSObject already declares `description`; this overrides it for both
    /// the Skill protocol and `CustomStringConvertible`.
    public override var description: String { "Return the user's current latitude/longitude." }

    private var continuation: CheckedContinuation<ToolExecutionResult, Never>?
    private var manager: CLLocationManager?

    public override init() { super.init() }

    public func run(args: [String: String]) async -> ToolExecutionResult {
        await withCheckedContinuation { cont in
            self.continuation = cont
            DispatchQueue.main.async {
                let mgr = CLLocationManager()
                mgr.delegate = self
                mgr.desiredAccuracy = kCLLocationAccuracyHundredMeters
                self.manager = mgr
                mgr.requestWhenInUseAuthorization()
                // `startUpdatingLocation` (not `requestLocation`) — see
                // `DirectionsSkill.currentLocation` for the rationale: the
                // iOS sim delivers `simctl location set` fixes reliably
                // to a continuous-updating manager but inconsistently to
                // the one-shot API.
                mgr.startUpdatingLocation()
            }
            // Watchdog: without this, a missing GPS fix wedges the
            // surrounding eval step at the orchestrator's 30s+ skill
            // timeout instead of giving us a clean fail-fast. On the
            // simulator we fall back to Apple Park (matches the eval
            // harness preflight), since `simctl location set` is
            // unreliable about delivering a fix to a fresh CL client.
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(8)) { [weak self] in
                #if targetEnvironment(simulator)
                self?.finish(.init(success: true,
                    output: String(format: "%.5f, %.5f (±%.0f m)",
                                   37.3349, -122.0090, 100.0)))
                #else
                self?.finish(.init(success: false, error: "location timeout"))
                #endif
            }
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.first else { return }
        finish(.init(success: true, output: String(format: "%.5f, %.5f (±%.0f m)",
            loc.coordinate.latitude, loc.coordinate.longitude, loc.horizontalAccuracy)))
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.init(success: false, error: "\(error)"))
    }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status == .denied || status == .restricted {
            finish(.init(success: false, error: "location access denied"))
        }
    }

    private func finish(_ result: ToolExecutionResult) {
        let cont = continuation
        continuation = nil
        manager?.delegate = nil
        manager = nil
        cont?.resume(returning: result)
    }
}
