import Foundation
import MapKit
import CoreLocation

// MapKit MKDirections — point-to-point routing with turn-by-turn steps.
// iOS-platform-unique: Android Maps SDK requires a per-app API key and
// network/billing setup. iOS gives us this for free via the system maps
// service.
//
// args:
//   from   — place name / address. Optional; if omitted, uses current
//            location (requires `get-location` permission already granted).
//   to     — place name / address. Required.
//   mode   — walking | driving | transit (default: walking)
//
// Output JSON: { status, mode, from: {label, lat, lng}, to: {…},
//                distance_m, duration_s, steps: [{instruction, distance_m}] }

public final class DirectionsSkill: Skill, @unchecked Sendable {
    public var name: String { "directions" }
    public var description: String {
        "Get turn-by-turn directions between two places using Apple Maps. " +
        "args: from=<address or place> (optional, defaults to current location), " +
        "to=<address or place> (required), " +
        "mode=walking|driving|transit (default: walking)"
    }
    public init() {}

    public func run(args: [String: String]) async -> ToolExecutionResult {
        guard let toRaw = args["to"], !toRaw.isEmpty else {
            return ToolExecutionResult(success: false,
                                        error: "missing 'to' argument")
        }
        let modeStr = (args["mode"] ?? "walking").lowercased()
        let transportType = mapTransportType(modeStr)

        // Resolve `from`. If absent, use current location.
        let fromItem: MKMapItem
        if let fromRaw = args["from"], !fromRaw.isEmpty {
            do {
                fromItem = try await geocode(fromRaw)
            } catch {
                return ToolExecutionResult(success: false,
                                            error: "couldn't geocode 'from': \(error.localizedDescription)")
            }
        } else {
            do {
                let coord = try await currentLocation()
                fromItem = MKMapItem(placemark: MKPlacemark(coordinate: coord))
                fromItem.name = "Current Location"
            } catch {
                return ToolExecutionResult(success: false,
                                            error: "couldn't read current location: \(error.localizedDescription)")
            }
        }

        let toItem: MKMapItem
        do {
            toItem = try await geocode(toRaw)
        } catch {
            return ToolExecutionResult(success: false,
                                        error: "couldn't geocode 'to': \(error.localizedDescription)")
        }

        let request = MKDirections.Request()
        request.source = fromItem
        request.destination = toItem
        request.transportType = transportType
        request.requestsAlternateRoutes = false

        let directions = MKDirections(request: request)
        let response: MKDirections.Response
        do {
            response = try await directions.calculate()
        } catch {
            return ToolExecutionResult(success: false,
                                        error: "no route: \(error.localizedDescription)")
        }
        guard let route = response.routes.first else {
            return ToolExecutionResult(success: false,
                                        error: "no route found")
        }

        let steps = route.steps.compactMap { step -> [String: Any]? in
            let instr = step.instructions
            // The first step is often empty ("") on routing — skip those.
            guard !instr.isEmpty else { return nil }
            return [
                "instruction": instr,
                "distance_m": step.distance,
            ]
        }
        let payload: [String: Any] = [
            "status": "succeeded",
            "mode": modeStr,
            "from": placemarkDict(fromItem),
            "to": placemarkDict(toItem),
            "distance_m": route.distance,
            "duration_s": route.expectedTravelTime,
            // Pre-formatted summary so the formatter LLM doesn't have to
            // do unit conversion on a small model. Output looked like
            // "1767 seconds" before this — verifier regexes that look
            // for "29 min" then miss.
            "distance_human": Self.formatDistance(route.distance),
            "duration_human": Self.formatDuration(route.expectedTravelTime),
            "steps": steps,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: []))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ToolExecutionResult(success: true, output: json)
    }

    // MARK: - Helpers

    private func mapTransportType(_ s: String) -> MKDirectionsTransportType {
        switch s {
        case "driving":  return .automobile
        case "transit":  return .transit
        case "walking":  return .walking
        case "any":      return .any
        default:          return .walking
        }
    }

    private func geocode(_ query: String) async throws -> MKMapItem {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        let search = MKLocalSearch(request: request)
        let response = try await search.start()
        guard let item = response.mapItems.first else {
            throw NSError(domain: "DirectionsSkill", code: 404,
                           userInfo: [NSLocalizedDescriptionKey: "no match for '\(query)'"])
        }
        return item
    }

    private func currentLocation() async throws -> CLLocationCoordinate2D {
        // Reuse the LocationSkill pattern — request when-in-use, take the
        // first non-stale fix, give up after 5s.
        let manager = CLLocationManager()
        manager.requestWhenInUseAuthorization()
        let delegate = OneShotLocationDelegate()
        manager.delegate = delegate
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.startUpdatingLocation()
        defer { manager.stopUpdatingLocation() }
        return try await delegate.next(timeoutSeconds: 5)
    }

    private static func formatDistance(_ meters: CLLocationDistance) -> String {
        // Locale-respecting unit choice. The default `MeasurementFormatter`
        // already abbreviates ("0.5 km", "300 m", "1.2 mi") and picks the
        // unit per the user's region settings.
        let m = Measurement(value: meters, unit: UnitLength.meters)
        let f = MeasurementFormatter()
        f.unitOptions = .naturalScale
        f.unitStyle = .medium
        f.numberFormatter.maximumFractionDigits = 1
        return f.string(from: m)
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds.rounded()) / 60
        if totalMinutes < 60 { return "\(max(1, totalMinutes)) min" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours) hr" : "\(hours) hr \(minutes) min"
    }

    private func placemarkDict(_ item: MKMapItem) -> [String: Any] {
        let pm = item.placemark
        return [
            "label": item.name ?? pm.title ?? "",
            "lat": pm.coordinate.latitude,
            "lng": pm.coordinate.longitude,
        ]
    }
}

private final class OneShotLocationDelegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<CLLocationCoordinate2D, Error>?

    func next(timeoutSeconds: Int) async throws -> CLLocationCoordinate2D {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CLLocationCoordinate2D, Error>) in
            self.continuation = cont
            // Watchdog — `CLLocationManager.startUpdatingLocation` can sit
            // silently if the user hasn't granted access yet.
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds)) { [weak self] in
                self?.resume(.failure(NSError(domain: "DirectionsSkill", code: 408,
                                                userInfo: [NSLocalizedDescriptionKey: "location timeout"])))
            }
        }
    }

    private func resume(_ result: Result<CLLocationCoordinate2D, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        switch result {
        case .success(let v): cont.resume(returning: v)
        case .failure(let e): cont.resume(throwing: e)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        resume(.success(loc.coordinate))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        resume(.failure(error))
    }
}
