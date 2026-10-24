//
//  DemoSimulatorTests.swift
//  PotholeMeshTests
//
//  Deterministic trip parameters, phase logic, failure handling, reset, and the
//  bounded event log for the Demo simulator. Uses a scripted APIClientProtocol
//  fake; no network.
//

import XCTest
@testable import PotholeMesh

private func makeDefect(id: Int = 1, state: DefectState = .suspected, p: Int = 1, n: Int = 0) -> RoadDefect {
    let date = Date(timeIntervalSince1970: 1_767_268_800)
    return RoadDefect(
        id: id, latitude: 42.355, longitude: -71.065, state: state,
        confidence: 0.5, severity: 58, positiveObservationCount: p,
        positiveUniqueDeviceCount: p, cleanCrossingCount: n, cleanUniqueDeviceCount: n,
        firstSeen: date, lastSeen: date, createdAt: date, updatedAt: date
    )
}

private func response(_ defect: RoadDefect, created: Bool = false, transition: Transition? = nil) -> IngestResponse {
    IngestResponse(evidenceId: 1, duplicate: false, created: created, transition: transition, defect: defect)
}

@MainActor
private final class ScriptedAPIClient: APIClientProtocol {
    var postResults: [Result<IngestResponse, APIError>] = []
    var defectResult: Result<RoadDefect, APIError> = .failure(.http(status: 404))
    /// When set, `resetDemo()` throws this error (the call is still counted).
    var resetError: APIError?
    private(set) var posted: [EvidencePayload] = []
    private(set) var resetCount = 0

    func health() async throws(APIError) {}
    func defects() async throws(APIError) -> [RoadDefect] { [] }
    func defect(id: Int) async throws(APIError) -> RoadDefect { try defectResult.get() }
    func resetDemo() async throws(APIError) {
        resetCount += 1
        if let resetError { throw resetError }
    }

    func postEvidence(_ payload: EvidencePayload) async throws(APIError) -> IngestResponse {
        posted.append(payload)
        guard !postResults.isEmpty else { throw .unreachable }
        return try postResults.removeFirst().get()
    }
}

private func haversineM(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
    let r = 6_371_000.0
    let dLat = (lat2 - lat1) * .pi / 180
    let dLon = (lon2 - lon1) * .pi / 180
    let a = sin(dLat / 2) * sin(dLat / 2)
        + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
    return 2 * r * asin(min(1, a.squareRoot()))
}

@MainActor
final class DemoSimulatorTests: XCTestCase {
    private let lat = 42.35500
    private let lon = -71.06500

    // MARK: Trip parameters

    func testTripParametersFollowFormulasAndStayWithinSixMeters() {
        for k in 1...200 {
            let trip = DemoTrip(k: k, centerLatitude: lat, centerLongitude: lon)
            XCTAssertLessThanOrEqual(haversineM(lat, lon, trip.latitude, trip.longitude), 6.01, "k=\(k)")
            XCTAssertEqual(trip.impactScore, DemoTrip.scores[(k - 1) % 8])
            XCTAssertEqual(trip.peakAcceleration, 0.4 + trip.impactScore / 50, accuracy: 1e-12)
            XCTAssertEqual(trip.peakJerk, 10 + trip.impactScore / 2, accuracy: 1e-12)
            XCTAssertEqual(trip.rotationRate, 0.6 + 0.1 * Double(k % 5), accuracy: 1e-12)
            XCTAssertEqual(trip.speedMps, 8 + Double((3 * k) % 7))
            XCTAssertEqual(trip.gpsAccuracyM, 3 + Double(k % 6))
            XCTAssertEqual(trip, DemoTrip(k: k, centerLatitude: lat, centerLongitude: lon), "deterministic")
        }
        XCTAssertEqual(DemoTrip.vehicleLabel(3), "Vehicle 03")
        XCTAssertEqual(DemoTrip.vehicleLabel(123), "Vehicle 123")
    }

    func testTripIntervalMatchesRateAndSpeed() {
        XCTAssertEqual(DemoTrip.interval(rate: .low, speed: .x1), 10.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(DemoTrip.interval(rate: .medium, speed: .x1), 1.0, accuracy: 1e-12)
        XCTAssertEqual(DemoTrip.interval(rate: .medium, speed: .x2), 0.5, accuracy: 1e-12)
        XCTAssertEqual(DemoTrip.interval(rate: .high, speed: .x5), 0.08, accuracy: 1e-12)
    }

    // MARK: Phase logic

    func testFullPhaseSequenceImpactsThenCleanCrossingsThenSilenceAfterResolved() async {
        let api = ScriptedAPIClient()
        let sim = DemoSimulator(api: api, centerLatitude: lat, centerLongitude: lon)

        // No pothole yet: trip posts nothing but still advances k.
        await sim.runTrip()
        XCTAssertTrue(api.posted.isEmpty)
        XCTAssertEqual(sim.nextTripNumber, 2)

        sim.injectPothole()
        api.postResults = [
            .success(response(makeDefect(id: 7), created: true)),
            .success(response(makeDefect(id: 7, p: 2))),
            .success(response(makeDefect(id: 7, state: .confirmed, p: 3),
                              transition: Transition(from: .suspected, to: .confirmed))),
        ]
        for _ in 0..<3 { await sim.runTrip() }

        XCTAssertEqual(api.posted.map(\.type), [.impact, .impact, .impact])
        XCTAssertTrue(api.posted.allSatisfy { $0.isSimulated })
        XCTAssertEqual(Set(api.posted.map(\.deviceId)).count, 3, "fresh device per trip")
        XCTAssertEqual(api.posted.first?.impactScore, DemoTrip.scores[1], "trip k=2 uses SCORES[1]")
        XCTAssertEqual(sim.demoDefectId, 7)
        XCTAssertEqual(sim.demoDefect?.state, .confirmed)
        let texts = sim.log.entries.map(\.text)
        XCTAssertTrue(texts.contains("Vehicle 02: impact detected (score 72)"))
        XCTAssertTrue(texts.contains("Defect #7 created · suspected"))
        XCTAssertTrue(texts.contains("Defect #7 confirmed"))

        sim.repairPothole()
        api.postResults = [
            .success(response(makeDefect(id: 7, state: .confirmed, p: 3, n: 1))),
            .success(response(makeDefect(id: 7, state: .resolved, p: 3, n: 6),
                              transition: Transition(from: .confirmed, to: .resolved))),
        ]
        await sim.runTrip()
        await sim.runTrip()
        XCTAssertEqual(api.posted.suffix(2).map(\.type), [.cleanCrossing, .cleanCrossing])
        XCTAssertEqual(api.posted.suffix(2).map(\.roadDefectId), [7, 7])
        XCTAssertTrue(sim.hasSeenResolved)
        XCTAssertTrue(sim.log.entries.map(\.text).contains("Defect #7 resolved"))

        // After RESOLVED: trips keep counting but post nothing.
        let postedBefore = api.posted.count
        let kBefore = sim.nextTripNumber
        await sim.runTrip()
        await sim.runTrip()
        XCTAssertEqual(api.posted.count, postedBefore)
        XCTAssertEqual(sim.nextTripNumber, kBefore + 2)
    }

    func testRepairWithoutDefectIdPostsNothing() async {
        let api = ScriptedAPIClient()
        let sim = DemoSimulator(api: api, centerLatitude: lat, centerLongitude: lon)
        sim.injectPothole()
        sim.repairPothole()
        await sim.runTrip()
        XCTAssertTrue(api.posted.isEmpty)
        XCTAssertEqual(sim.nextTripNumber, 2)
    }

    func testConflictOnCleanCrossingMarksResolvedAndRefreshesCard() async {
        let api = ScriptedAPIClient()
        let sim = DemoSimulator(api: api, centerLatitude: lat, centerLongitude: lon)
        sim.injectPothole()
        api.postResults = [.success(response(makeDefect(id: 4), created: true))]
        await sim.runTrip()

        sim.repairPothole()
        api.postResults = [.failure(.http(status: 409))]
        api.defectResult = .success(makeDefect(id: 4, state: .resolved))
        await sim.runTrip()
        XCTAssertTrue(sim.hasSeenResolved)
        XCTAssertEqual(sim.demoDefect?.state, .resolved)

        let count = api.posted.count
        await sim.runTrip()
        XCTAssertEqual(api.posted.count, count, "no evidence after RESOLVED is seen")
    }

    // MARK: Failures

    func testThreeConsecutiveConnectivityFailuresStall() async {
        let api = ScriptedAPIClient()
        let sim = DemoSimulator(api: api, centerLatitude: lat, centerLongitude: lon)
        sim.injectPothole()

        api.postResults = [.failure(.unreachable), .failure(.timeout)]
        await sim.runTrip()
        await sim.runTrip()
        XCTAssertFalse(sim.isStalled)
        XCTAssertEqual(sim.log.entries.filter { $0.text == "Server unreachable, retrying" }.count, 2)

        // A success in between resets the streak.
        api.postResults = [.success(response(makeDefect(id: 1), created: true)),
                           .failure(.unreachable), .failure(.unreachable)]
        for _ in 0..<3 { await sim.runTrip() }
        XCTAssertFalse(sim.isStalled)

        api.postResults = [.failure(.timeout)]
        await sim.runTrip()
        XCTAssertTrue(sim.isStalled)
    }

    func testClientErrorIsLoggedAndDroppedWithoutRetry() async {
        let api = ScriptedAPIClient()
        let sim = DemoSimulator(api: api, centerLatitude: lat, centerLongitude: lon)
        sim.injectPothole()
        api.postResults = [.failure(.http(status: 422)), .success(response(makeDefect(id: 2), created: true))]
        await sim.runTrip()
        await sim.runTrip()
        XCTAssertEqual(api.posted.count, 2, "the rejected payload is not re-posted")
        XCTAssertNotEqual(api.posted[0].deviceId, api.posted[1].deviceId)
        XCTAssertTrue(sim.log.entries.contains { $0.text.contains("HTTP 422") })
        XCTAssertFalse(sim.isStalled)
    }

    // MARK: Reset

    func testResetRestoresInitialStateAndCallsBackend() async {
        let api = ScriptedAPIClient()
        let sim = DemoSimulator(api: api, centerLatitude: lat, centerLongitude: lon)
        sim.injectPothole()
        api.postResults = [.success(response(makeDefect(id: 9), created: true))]
        await sim.runTrip()
        sim.repairPothole()

        await sim.resetDemo()
        XCTAssertEqual(api.resetCount, 1)
        XCTAssertEqual(sim.nextTripNumber, 1)
        XCTAssertFalse(sim.hasPothole)
        XCTAssertFalse(sim.isRepaired)
        XCTAssertNil(sim.demoDefectId)
        XCTAssertNil(sim.demoDefect)
        XCTAssertFalse(sim.isRunning)
        XCTAssertTrue(sim.log.isEmpty)
    }

    func testFailedResetPreservesLocalStateAndLogsWarning() async {
        let api = ScriptedAPIClient()
        let sim = DemoSimulator(api: api, centerLatitude: lat, centerLongitude: lon)
        sim.injectPothole()
        api.postResults = [.success(response(makeDefect(id: 9), created: true))]
        await sim.runTrip()
        sim.repairPothole()

        let kBefore = sim.nextTripNumber
        let defectBefore = sim.demoDefect
        let logBefore = sim.log.entries.map(\.text)
        XCTAssertFalse(logBefore.isEmpty)

        api.resetError = .unreachable
        await sim.resetDemo()

        XCTAssertEqual(api.resetCount, 1)
        XCTAssertEqual(sim.nextTripNumber, kBefore)
        XCTAssertTrue(sim.hasPothole)
        XCTAssertTrue(sim.isRepaired)
        XCTAssertEqual(sim.demoDefectId, 9)
        XCTAssertEqual(sim.demoDefect, defectBefore)
        XCTAssertFalse(sim.isRunning)
        XCTAssertFalse(sim.isResetting)
        let texts = sim.log.entries.map(\.text)
        XCTAssertEqual(Array(texts.dropLast()), logBefore, "prior log entries preserved")
        XCTAssertEqual(texts.last, "Reset failed — server unreachable")
        XCTAssertEqual(sim.log.entries.last?.kind, .warning)

        // Non-connectivity errors carry their reason.
        api.resetError = .http(status: 500)
        await sim.resetDemo()
        XCTAssertEqual(sim.log.entries.last?.text, "Reset failed — HTTP 500")
        XCTAssertEqual(sim.demoDefectId, 9)
    }

    // MARK: Event log

    func testEventLogKeepsOnlyTheMostRecentFifty() {
        var log = DemoEventLog()
        for i in 0..<75 { log.append("entry \(i)", kind: .info) }
        XCTAssertEqual(log.entries.count, DemoEventLog.capacity)
        XCTAssertEqual(log.entries.first?.text, "entry 25")
        XCTAssertEqual(log.newestFirst.first?.text, "entry 74")
    }
}
