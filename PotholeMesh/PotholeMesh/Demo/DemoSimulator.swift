//
//  DemoSimulator.swift
//  PotholeMesh
//
//  Deterministic virtual traffic over a virtual pothole (Requirements 12, 13).
//  Ground truth stays on the device; the backend learns about the pothole only
//  through evidence posted to the same `POST /evidence` endpoint real phones use,
//  with `is_simulated = true`.
//

import Foundation
import Observation
import os

// MARK: - Controls

nonisolated enum TrafficRate: String, CaseIterable, Identifiable, Sendable {
    case low, medium, high

    var id: Self { self }

    var displayName: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    /// Trips per base lap (10 s).
    var rateFactor: Double {
        switch self {
        case .low: 3
        case .medium: 10
        case .high: 25
        }
    }
}

nonisolated enum SimulationSpeed: Int, CaseIterable, Identifiable, Sendable {
    case x1 = 1, x2 = 2, x5 = 5

    var id: Self { self }
    var displayName: String { "\(rawValue)x" }
    var multiplier: Double { Double(rawValue) }
}

// MARK: - Deterministic trip parameters

/// Every evidence value for trip k, as a pure function of k (Requirement 12.4, 12.5).
nonisolated struct DemoTrip: Equatable, Sendable {
    static let baseLapSeconds = 10.0
    static let scores: [Double] = [58, 72, 64, 69, 55, 76, 61, 67]
    static let spiralRadiusM = 6.0
    static let goldenAngleDegrees = 137.508
    static let metersPerDegreeLatitude = 111_320.0

    let k: Int
    let latitude: Double
    let longitude: Double
    let impactScore: Double
    let peakAcceleration: Double
    let peakJerk: Double
    let rotationRate: Double
    let speedMps: Double
    let gpsAccuracyM: Double

    init(k: Int, centerLatitude: Double, centerLongitude: Double) {
        self.k = k
        let theta = Double(k) * Self.goldenAngleDegrees * .pi / 180
        let ring = Double(Self.mod(k - 1, 16) + 1) / 16
        let r = Self.spiralRadiusM * ring.squareRoot()
        let latitudeRadians = centerLatitude * .pi / 180
        latitude = centerLatitude + r * cos(theta) / Self.metersPerDegreeLatitude
        longitude = centerLongitude + r * sin(theta) / (Self.metersPerDegreeLatitude * cos(latitudeRadians))

        let score = Self.scores[Self.mod(k - 1, Self.scores.count)]
        impactScore = score
        peakAcceleration = 0.4 + score / 50
        peakJerk = 10 + score / 2
        rotationRate = 0.6 + 0.1 * Double(Self.mod(k, 5))
        speedMps = 8 + Double(Self.mod(3 * k, 7))
        gpsAccuracyM = 3 + Double(Self.mod(k, 6))
    }

    /// "Vehicle 01", "Vehicle 02", ... (k zero-padded to at least two digits).
    var vehicleLabel: String { Self.vehicleLabel(k) }

    static func vehicleLabel(_ k: Int) -> String {
        String(format: "Vehicle %02d", k)
    }

    /// Seconds between trips: 10 s / rateFactor / speed.
    static func interval(rate: TrafficRate, speed: SimulationSpeed) -> Double {
        baseLapSeconds / rate.rateFactor / speed.multiplier
    }

    /// Non-negative modulo.
    private static func mod(_ a: Int, _ n: Int) -> Int {
        ((a % n) + n) % n
    }
}

// MARK: - Simulator

@Observable
final class DemoSimulator {
    private static let logger = Logger(subsystem: "com.hackachusetts.PotholeMesh", category: "DemoSimulator")

    /// Consecutive connectivity failures that pause traffic (Requirement 13.8).
    static let maxConsecutiveFailures = 3

    // Ground truth, local to the device only.
    private(set) var hasPothole = false
    private(set) var isRepaired = false
    let centerLatitude: Double
    let centerLongitude: Double

    // Traffic.
    var rate: TrafficRate = .low
    var speed: SimulationSpeed = .x1
    private(set) var isRunning = false
    /// Sequence number k of the next trip.
    private(set) var nextTripNumber = 1
    /// True after traffic paused itself on repeated connectivity failures.
    private(set) var isStalled = false
    private(set) var isResetting = false
    private(set) var consecutiveFailures = 0

    // What the backend told us about the demo defect.
    private(set) var demoDefectId: Int?
    private(set) var demoDefect: RoadDefect?
    /// Once the demo defect is seen as RESOLVED, trips post nothing until RESET DEMO.
    private(set) var hasSeenResolved = false

    private(set) var log = DemoEventLog()

    @ObservationIgnored private let api: APIClientProtocol
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let makeDeviceId: () -> String
    @ObservationIgnored private var trafficTask: Task<Void, Never>?

    init(
        api: APIClientProtocol,
        centerLatitude: Double = AppConfig.demoLatitude,
        centerLongitude: Double = AppConfig.demoLongitude,
        now: @escaping () -> Date = Date.init,
        makeDeviceId: @escaping () -> String = { UUID().uuidString }
    ) {
        self.api = api
        self.centerLatitude = centerLatitude
        self.centerLongitude = centerLongitude
        self.now = now
        self.makeDeviceId = makeDeviceId
    }

    /// Seconds between trips at the current rate and speed.
    var tripInterval: Double { DemoTrip.interval(rate: rate, speed: speed) }

    // MARK: Controls

    func injectPothole() {
        hasPothole = true
        isRepaired = false
        log.append("Pothole injected", kind: .info, date: now())
    }

    func repairPothole() {
        isRepaired = true
        log.append("Pothole repaired", kind: .info, date: now())
    }

    func toggleTraffic() {
        if isRunning {
            pauseTraffic()
        } else {
            startTraffic()
        }
    }

    /// Starts the traffic loop. The first trip runs one interval after start.
    /// Also serves as Resume after a stall.
    func startTraffic() {
        guard !isRunning, !isResetting else { return }
        isStalled = false
        consecutiveFailures = 0
        isRunning = true
        // Let any cancelled loop finish its in-flight request first, so at most
        // one simulator request is ever in flight.
        let previous = trafficTask
        trafficTask = Task { [weak self] in
            await previous?.value
            await self?.runLoop()
        }
    }

    func pauseTraffic() {
        trafficTask?.cancel()
        isRunning = false
    }

    /// Pauses traffic (awaiting any in-flight trip), then calls `POST /demo/reset`.
    /// Only if the backend reset succeeds is the simulator returned to its exact
    /// initial state. On failure, all local state (k, ground truth, demo defect,
    /// log) is preserved, traffic stays paused, and a "Reset failed — …" warning is
    /// logged, so the app and backend never silently diverge.
    func resetDemo() async {
        guard !isResetting else { return }
        isResetting = true
        defer { isResetting = false }

        isRunning = false
        let previous = trafficTask
        trafficTask = nil
        previous?.cancel()
        await previous?.value

        do {
            try await api.resetDemo()
        } catch {
            Self.logger.error("POST /demo/reset failed: \(String(describing: error), privacy: .public)")
            let reason = error.isConnectivity ? "server unreachable" : Self.describe(error)
            log.append("Reset failed — \(reason)", kind: .warning, date: now())
            return
        }

        nextTripNumber = 1
        hasPothole = false
        isRepaired = false
        demoDefectId = nil
        demoDefect = nil
        hasSeenResolved = false
        consecutiveFailures = 0
        isStalled = false
        log.clear()
    }

    /// Refreshes the status card from `GET /defects/{id}` (any state, including RESOLVED).
    func refreshDemoDefect() async {
        guard let id = demoDefectId else { return }
        do {
            let defect = try await api.defect(id: id)
            guard id == demoDefectId else { return }
            demoDefect = defect
            if defect.state == .resolved { hasSeenResolved = true }
        } catch {
            // Status card keeps its last value on any failure (Requirement 19.1).
            if error == .decoding {
                Self.logger.error("GET /defects/\(id) returned an undecodable body; keeping previous status")
            } else {
                Self.logger.debug("GET /defects/\(id) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Traffic loop

    private func runLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(tripInterval))
            } catch {
                return // cancelled
            }
            await runTrip()
            if isStalled {
                isRunning = false
                trafficTask = nil
                return
            }
        }
    }

    /// Runs one trip: assigns k, builds at most one payload for the current phase,
    /// and awaits its response before returning.
    func runTrip() async {
        let k = nextTripNumber
        nextTripNumber += 1
        let trip = DemoTrip(k: k, centerLatitude: centerLatitude, centerLongitude: centerLongitude)
        guard let payload = payload(for: trip) else { return }

        do {
            let result = try await api.postEvidence(payload)
            consecutiveFailures = 0
            apply(result, payload: payload, vehicle: trip.vehicleLabel)
        } catch {
            await handleFailure(error, payload: payload, vehicle: trip.vehicleLabel)
        }
    }

    /// The evidence for this trip, or nil when the trip should post nothing.
    private func payload(for trip: DemoTrip) -> EvidencePayload? {
        guard !hasSeenResolved else { return nil }
        let deviceId = makeDeviceId()
        if hasPothole && !isRepaired {
            return .impact(
                deviceId: deviceId,
                latitude: trip.latitude, longitude: trip.longitude,
                timestamp: now(),
                speedMps: trip.speedMps, gpsAccuracyM: trip.gpsAccuracyM,
                impactScore: trip.impactScore,
                peakAcceleration: trip.peakAcceleration,
                peakJerk: trip.peakJerk,
                rotationRate: trip.rotationRate,
                isSimulated: true
            )
        }
        if isRepaired, let defectId = demoDefectId {
            return .cleanCrossing(
                deviceId: deviceId, roadDefectId: defectId,
                latitude: trip.latitude, longitude: trip.longitude,
                timestamp: now(),
                speedMps: trip.speedMps, gpsAccuracyM: trip.gpsAccuracyM,
                isSimulated: true
            )
        }
        return nil
    }

    private func apply(_ result: IngestResponse, payload: EvidencePayload, vehicle: String) {
        if payload.type == .impact, demoDefectId == nil {
            demoDefectId = result.defect.id
        }
        if result.defect.id == demoDefectId {
            demoDefect = result.defect
        }
        let date = now()
        for line in DemoEventLog.messages(for: result, payload: payload, vehicle: vehicle) {
            log.append(line.text, kind: line.kind, date: date)
        }
        if result.defect.id == demoDefectId,
           result.transition?.to == .resolved || result.defect.state == .resolved {
            hasSeenResolved = true
        }
    }

    private func handleFailure(_ error: APIError, payload: EvidencePayload, vehicle: String) async {
        // Pausing cancels the in-flight request; that isn't a server problem.
        if Task.isCancelled && error.isConnectivity { return }

        switch error {
        case .unreachable, .timeout:
            consecutiveFailures += 1
            log.append("Server unreachable, retrying", kind: .warning, date: now())
            if consecutiveFailures >= Self.maxConsecutiveFailures {
                isStalled = true
                log.append("Traffic paused: server unreachable", kind: .warning, date: now())
            }
        case .http(let status) where status == 409 && payload.type == .cleanCrossing:
            consecutiveFailures = 0
            hasSeenResolved = true
            let id = payload.roadDefectId.map { "#\($0)" } ?? ""
            log.append("\(vehicle): defect \(id) already resolved (HTTP 409)", kind: .info, date: now())
            await refreshDemoDefect()
        case .http(let status) where (400...499).contains(status):
            consecutiveFailures = 0
            log.append("\(vehicle): rejected by server (HTTP \(status)), dropped", kind: .warning, date: now())
        case .http(let status):
            log.append("\(vehicle): server error (HTTP \(status)), dropped", kind: .warning, date: now())
        case .decoding:
            Self.logger.error("Undecodable ingest response; keeping previous state")
            log.append("\(vehicle): unreadable server response, ignored", kind: .warning, date: now())
        }
    }

    static func describe(_ error: APIError) -> String {
        switch error {
        case .unreachable: "server unreachable"
        case .timeout: "request timed out"
        case .http(let status): "HTTP \(status)"
        case .decoding: "unreadable response"
        }
    }
}
