//
//  AppFoundationTests.swift
//  PotholeMeshTests
//
//  Coding, configuration, identity, API error mapping, and DefectStore polling behavior.
//

import XCTest
@testable import PotholeMesh

// MARK: - Fixtures

private let defectJSON = """
{"id":1,"latitude":42.35501,"longitude":-71.06498,"state":"CONFIRMED","confidence":0.7,
 "severity":64.0,"positive_observation_count":3,"positive_unique_device_count":3,
 "clean_crossing_count":0,"clean_unique_device_count":0,
 "first_seen":"2026-01-01T12:00:00Z","last_seen":"2026-01-01T12:00:10Z",
 "created_at":"2026-01-01T12:00:00Z","updated_at":"2026-01-01T12:00:10.250Z"}
"""

private func makeDefect(id: Int, state: DefectState = .suspected) -> RoadDefect {
    let date = Date(timeIntervalSince1970: 1_767_268_800)
    return RoadDefect(
        id: id, latitude: 42.355, longitude: -71.065, state: state,
        confidence: 0.5, severity: 58, positiveObservationCount: 1,
        positiveUniqueDeviceCount: 1, cleanCrossingCount: 0, cleanUniqueDeviceCount: 0,
        firstSeen: date, lastSeen: date, createdAt: date, updatedAt: date
    )
}

@MainActor
private final class FakeAPIClient: APIClientProtocol {
    var defectsResults: [Result<[RoadDefect], APIError>] = []
    private(set) var defectsCallCount = 0

    func health() async throws(APIError) {}
    func postEvidence(_ payload: EvidencePayload) async throws(APIError) -> IngestResponse { throw .unreachable }
    func defect(id: Int) async throws(APIError) -> RoadDefect { throw .http(status: 404) }
    func resetDemo() async throws(APIError) {}

    func defects() async throws(APIError) -> [RoadDefect] {
        defectsCallCount += 1
        guard !defectsResults.isEmpty else { return [] }
        return try defectsResults.removeFirst().get()
    }
}

/// Transport-level stub so APIClient status/error mapping runs without a server.
private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> Result<(Int, Data), URLError>)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        switch handler(request) {
        case .success(let (status, data)):
            if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

// MARK: - Tests

@MainActor
final class AppFoundationTests: XCTestCase {

    // MARK: Coding

    func testDecodesBackendDefectWithSecondAndFractionalTimestamps() throws {
        let defect = try JSONCoding.makeDecoder().decode(RoadDefect.self, from: Data(defectJSON.utf8))
        XCTAssertEqual(defect.id, 1)
        XCTAssertEqual(defect.state, .confirmed)
        XCTAssertEqual(defect.positiveUniqueDeviceCount, 3)
        XCTAssertEqual(defect.severityBand, .moderate)
        XCTAssertEqual(defect.lastSeen.timeIntervalSince(defect.firstSeen), 10, accuracy: 0.001)
        XCTAssertEqual(defect.updatedAt.timeIntervalSince(defect.firstSeen), 10.25, accuracy: 0.001)
    }

    func testDecodesIngestResponseWithAndWithoutTransition() throws {
        let decoder = JSONCoding.makeDecoder()
        let withTransition = """
        {"evidence_id":17,"duplicate":false,"created":false,
         "transition":{"from":"SUSPECTED","to":"CONFIRMED"},"defect":\(defectJSON)}
        """
        let a = try decoder.decode(IngestResponse.self, from: Data(withTransition.utf8))
        XCTAssertEqual(a.evidenceId, 17)
        XCTAssertEqual(a.transition, Transition(from: .suspected, to: .confirmed))

        let noTransition = """
        {"evidence_id":3,"duplicate":true,"created":false,"transition":null,"defect":\(defectJSON)}
        """
        let b = try decoder.decode(IngestResponse.self, from: Data(noTransition.utf8))
        XCTAssertTrue(b.duplicate)
        XCTAssertNil(b.transition)
    }

    func testEncodesCleanCrossingWithSnakeCaseKeysAndNoImpactFields() throws {
        let payload = EvidencePayload.cleanCrossing(
            deviceId: "abc", roadDefectId: 7, latitude: 42.355, longitude: -71.065,
            timestamp: Date(timeIntervalSince1970: 1_767_268_800.5),
            speedMps: 9, gpsAccuracyM: 4, isSimulated: true)
        let data = try JSONCoding.makeEncoder().encode(payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "clean_crossing")
        XCTAssertEqual(json["device_id"] as? String, "abc")
        XCTAssertEqual(json["road_defect_id"] as? Int, 7)
        XCTAssertEqual(json["gps_accuracy_m"] as? Double, 4)
        XCTAssertEqual(json["speed_mps"] as? Double, 9)
        XCTAssertEqual(json["is_simulated"] as? Bool, true)
        XCTAssertNil(json["impact_score"])
        let timestamp = try XCTUnwrap(json["timestamp"] as? String)
        XCTAssertEqual(timestamp, "2026-01-01T12:00:00.500Z")

        // Round trip back through the app decoder.
        let decoded = try JSONCoding.makeDecoder().decode(EvidencePayload.self, from: data)
        XCTAssertEqual(decoded, payload)
    }

    func testSeverityBandBoundaries() {
        XCTAssertEqual(SeverityBand(severity: 0), .low)
        XCTAssertEqual(SeverityBand(severity: 39.99), .low)
        XCTAssertEqual(SeverityBand(severity: 40), .moderate)
        XCTAssertEqual(SeverityBand(severity: 69.99), .moderate)
        XCTAssertEqual(SeverityBand(severity: 70), .high)
        XCTAssertEqual(SeverityBand(severity: 100), .high)
    }

    // MARK: Config and identity

    private func makeDefaults() throws -> UserDefaults {
        let name = "PotholeMeshTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testBaseURLUsesOverrideWhenStoredAndDefaultOtherwise() throws {
        let defaults = try makeDefaults()
        XCTAssertEqual(AppConfig.baseURLString(defaults: defaults), AppConfig.defaultBaseURLString)

        AppConfig.setBaseURLOverride("  192.168.1.20:8000/ ", defaults: defaults)
        XCTAssertEqual(AppConfig.baseURLString(defaults: defaults), "http://192.168.1.20:8000")
        XCTAssertEqual(AppConfig.baseURL(defaults: defaults)?.host(), "192.168.1.20")

        AppConfig.setBaseURLOverride("", defaults: defaults)
        XCTAssertEqual(AppConfig.baseURLString(defaults: defaults), AppConfig.defaultBaseURLString)
    }

    func testDeviceIdIsGeneratedOnceAndReused() throws {
        let defaults = try makeDefaults()
        let first = DeviceIdentity.deviceId(defaults: defaults)
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(DeviceIdentity.deviceId(defaults: defaults), first)
    }

    // MARK: APIClient error mapping

    private func makeStubbedClient(_ handler: @escaping (URLRequest) -> Result<(Int, Data), URLError>) throws -> URLSessionAPIClient {
        StubURLProtocol.handler = handler
        addTeardownBlock { StubURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let url = try XCTUnwrap(URL(string: "http://stub.local:8000"))
        return URLSessionAPIClient(session: URLSession(configuration: configuration), baseURLProvider: { url })
    }

    private func expectError(_ expected: APIError, _ operation: () async throws(APIError) -> Void,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }

    func testAPIClientDecodesDefectsAndHitsExpectedPath() async throws {
        let client = try makeStubbedClient { request in
            XCTAssertEqual(request.url?.path(), "/defects")
            return .success((200, Data("[\(defectJSON)]".utf8)))
        }
        let defects = try await client.defects()
        XCTAssertEqual(defects.map(\.id), [1])
    }

    func testAPIClientMapsFailuresToTypedErrors() async throws {
        let notFound = try makeStubbedClient { _ in .success((404, Data(#"{"detail":"x"}"#.utf8))) }
        await expectError(.http(status: 404)) { () async throws(APIError) in _ = try await notFound.defect(id: 99) }

        let garbage = try makeStubbedClient { _ in .success((200, Data("not json".utf8))) }
        await expectError(.decoding) { () async throws(APIError) in _ = try await garbage.defects() }

        let slow = try makeStubbedClient { _ in .failure(URLError(.timedOut)) }
        await expectError(.timeout) { () async throws(APIError) in _ = try await slow.defects() }

        let down = try makeStubbedClient { _ in .failure(URLError(.cannotConnectToHost)) }
        await expectError(.unreachable) { () async throws(APIError) in try await down.health() }
    }

    func testAPIClientWithInvalidBaseURLThrowsUnreachable() async {
        let client = URLSessionAPIClient(baseURLProvider: { nil })
        await expectError(.unreachable) { () async throws(APIError) in _ = try await client.defects() }
    }

    // MARK: DefectStore

    func testRefreshPublishesDefectsAndKeepsThemOnFailure() async {
        let api = FakeAPIClient()
        let t0 = Date(timeIntervalSince1970: 1_000)
        var clock = t0
        let store = DefectStore(api: api, now: { clock })

        api.defectsResults = [.success([makeDefect(id: 1), makeDefect(id: 2, state: .confirmed)])]
        await store.refresh()
        XCTAssertEqual(store.defects.map(\.id), [1, 2])
        XCTAssertEqual(store.lastRefresh, t0)
        XCTAssertEqual(store.connectionStatus, .connected)

        for failure in [APIError.unreachable, .timeout, .decoding, .http(status: 500)] {
            clock = clock.addingTimeInterval(2)
            api.defectsResults = [.failure(failure)]
            await store.refresh()
            XCTAssertEqual(store.defects.map(\.id), [1, 2], "kept on \(failure)")
            XCTAssertEqual(store.lastRefresh, t0, "refresh time kept on \(failure)")
            XCTAssertEqual(store.connectionStatus, .failed(failure))
        }
        XCTAssertTrue(store.connectionStatus.isConnected == false)

        clock = clock.addingTimeInterval(2)
        api.defectsResults = [.success([makeDefect(id: 2, state: .confirmed)])]
        await store.refresh()
        XCTAssertEqual(store.defects.map(\.id), [2])
        XCTAssertEqual(store.lastRefresh, clock)
        XCTAssertEqual(store.connectionStatus, .connected)
    }

    func testPollingStartsOnceAndStopsIssuingRequests() async throws {
        let api = FakeAPIClient()
        let store = DefectStore(api: api, pollInterval: .milliseconds(20))

        store.startPolling()
        store.startPolling() // second call must not start a second loop
        XCTAssertTrue(store.isPolling)
        try await Task.sleep(for: .milliseconds(150))
        store.stopPolling()
        XCTAssertFalse(store.isPolling)

        let callsAtStop = api.defectsCallCount
        XCTAssertGreaterThanOrEqual(callsAtStop, 2)
        // A single loop at 20 ms over ~150 ms can't exceed ~9 polls; two loops would double it.
        XCTAssertLessThanOrEqual(callsAtStop, 10)

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(api.defectsCallCount, callsAtStop)
    }
}
