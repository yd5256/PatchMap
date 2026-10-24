//
//  DriveServicesTests.swift
//  PotholeMeshTests
//
//  EvidenceUploader retry queue and backoff, location fix filtering, the raw-motion
//  ring buffer, and Drive status evaluation. No sensors, permissions, or network.
//

import XCTest
@testable import PotholeMesh

@MainActor
private final class UploadAPIClient: APIClientProtocol {
    /// Results consumed in order; when empty, posts succeed.
    var postResults: [APIError?] = []
    private(set) var posted: [EvidencePayload] = []

    func health() async throws(APIError) {}
    func defects() async throws(APIError) -> [RoadDefect] { [] }
    func defect(id: Int) async throws(APIError) -> RoadDefect { throw .http(status: 404) }
    func resetDemo() async throws(APIError) {}

    func postEvidence(_ payload: EvidencePayload) async throws(APIError) -> IngestResponse {
        posted.append(payload)
        if !postResults.isEmpty, let error = postResults.removeFirst() { throw error }
        let date = Date(timeIntervalSince1970: 1_767_268_800)
        let defect = RoadDefect(
            id: 1, latitude: payload.latitude, longitude: payload.longitude, state: .suspected,
            confidence: 0.5, severity: 50, positiveObservationCount: 1, positiveUniqueDeviceCount: 1,
            cleanCrossingCount: 0, cleanUniqueDeviceCount: 0,
            firstSeen: date, lastSeen: date, createdAt: date, updatedAt: date
        )
        return IngestResponse(evidenceId: posted.count, duplicate: false, created: true, transition: nil, defect: defect)
    }
}

private func payload(_ i: Int) -> EvidencePayload {
    .impact(deviceId: "device", latitude: 42.355, longitude: -71.065,
            timestamp: Date(timeIntervalSince1970: 1_767_268_800 + Double(i)),
            speedMps: 10, gpsAccuracyM: 5, impactScore: 60,
            peakAcceleration: 1.2, peakJerk: 30, rotationRate: 0.8, isSimulated: false)
}

@MainActor
final class EvidenceUploaderTests: XCTestCase {
    func testSuccessfulPostCountsAndQueuesNothing() async {
        let api = UploadAPIClient()
        let uploader = EvidenceUploader(api: api, autoRetry: false)
        await uploader.submit(payload(1))
        XCTAssertEqual(api.posted.count, 1)
        XCTAssertEqual(uploader.uploadedCount, 1)
        XCTAssertEqual(uploader.pendingCount, 0)
        XCTAssertNil(uploader.lastError)
    }

    func testRetryableFailuresQueueAndRetrySucceedsWithOriginalPayload() async {
        let api = UploadAPIClient()
        let uploader = EvidenceUploader(api: api, autoRetry: false)
        api.postResults = [.unreachable, .timeout, .http(status: 503)]
        await uploader.submit(payload(1))
        await uploader.submit(payload(2))
        await uploader.submit(payload(3))
        XCTAssertEqual(uploader.pendingCount, 3)
        XCTAssertEqual(uploader.uploadedCount, 0)
        XCTAssertTrue(uploader.lastError?.isRetryable ?? false)

        await uploader.retryOnce()
        XCTAssertEqual(api.posted.last, payload(1), "oldest first, unchanged timestamp")
        XCTAssertEqual(uploader.pendingCount, 2)
        XCTAssertEqual(uploader.uploadedCount, 1)
    }

    func testConnectivityFailureFlagsServerUnreachable() async {
        let api = UploadAPIClient()
        let uploader = EvidenceUploader(api: api, autoRetry: false)
        api.postResults = [.timeout]
        await uploader.submit(payload(1))
        XCTAssertTrue(uploader.lastUploadFailedConnectivity)
        await uploader.retryOnce()
        XCTAssertFalse(uploader.lastUploadFailedConnectivity)
    }

    func testClientErrorsAreDroppedWithoutRetry() async {
        let api = UploadAPIClient()
        let uploader = EvidenceUploader(api: api, autoRetry: false)
        api.postResults = [.http(status: 422)]
        await uploader.submit(payload(1))
        XCTAssertEqual(uploader.pendingCount, 0)

        // A queued item that later gets a 4xx is removed too.
        api.postResults = [.unreachable, .http(status: 409)]
        await uploader.submit(payload(2))
        XCTAssertEqual(uploader.pendingCount, 1)
        await uploader.retryOnce()
        XCTAssertEqual(uploader.pendingCount, 0)
        XCTAssertEqual(uploader.uploadedCount, 0)
    }

    func testBackoffDoublesCapsAtThirtyAndResetsOnSuccess() async {
        let api = UploadAPIClient()
        let uploader = EvidenceUploader(api: api, autoRetry: false)
        api.postResults = [.unreachable]
        await uploader.submit(payload(1))

        var delays: [Duration] = [uploader.retryDelay]
        api.postResults = Array(repeating: .unreachable, count: 6)
        for _ in 0..<6 {
            await uploader.retryOnce()
            delays.append(uploader.retryDelay)
        }
        XCTAssertEqual(delays, [2, 4, 8, 16, 30, 30, 30].map { Duration.seconds($0) })

        await uploader.retryOnce() // succeeds
        XCTAssertEqual(uploader.retryDelay, .seconds(2))
        XCTAssertEqual(uploader.pendingCount, 0)
    }

    func testQueueHoldsAtMostFiftyAndDropsOldest() async {
        let api = UploadAPIClient()
        let uploader = EvidenceUploader(api: api, autoRetry: false)
        api.postResults = Array(repeating: .unreachable, count: 55)
        for i in 1...55 { await uploader.submit(payload(i)) }
        XCTAssertEqual(uploader.pendingCount, EvidenceUploader.maxQueueSize)
        XCTAssertEqual(uploader.queue.first?.payload, payload(6))
        XCTAssertEqual(uploader.queue.last?.payload, payload(55))
    }
}

final class LocationFixTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_767_268_800)

    private func fix(accuracy: Double, age: TimeInterval, speed: Double = 10) -> LocationFix? {
        LocationFix.accepting(latitude: 42.355, longitude: -71.065, horizontalAccuracy: accuracy,
                              speed: speed, timestamp: now.addingTimeInterval(-age), now: now)
    }

    func testAcceptanceBoundaries() {
        XCTAssertNotNil(fix(accuracy: 20, age: 5), "exactly 20 m and 5 s are accepted")
        XCTAssertNil(fix(accuracy: 20.01, age: 0))
        XCTAssertNil(fix(accuracy: -1, age: 0))
        XCTAssertNil(fix(accuracy: 5, age: 5.01))
    }

    func testNegativeSpeedBecomesUnknown() {
        XCTAssertNil(fix(accuracy: 5, age: 0, speed: -1)?.speedMps)
        XCTAssertEqual(fix(accuracy: 5, age: 0, speed: 0)?.speedMps, 0)
    }

    func testGPSStatusEvaluation() {
        let good = fix(accuracy: 5, age: 0)
        XCTAssertEqual(GPSStatus.evaluate(authorization: .denied, latestFix: good, hasReceivedAnyFix: true, now: now), .denied)
        XCTAssertEqual(GPSStatus.evaluate(authorization: .restricted, latestFix: nil, hasReceivedAnyFix: false, now: now), .denied)
        XCTAssertEqual(GPSStatus.evaluate(authorization: .whenInUse, latestFix: nil, hasReceivedAnyFix: false, now: now), .searching)
        XCTAssertEqual(GPSStatus.evaluate(authorization: .whenInUse, latestFix: nil, hasReceivedAnyFix: true, now: now), .poor)
        XCTAssertEqual(GPSStatus.evaluate(authorization: .whenInUse, latestFix: good, hasReceivedAnyFix: true, now: now), .good)
        XCTAssertEqual(GPSStatus.evaluate(authorization: .whenInUse, latestFix: good, hasReceivedAnyFix: true,
                                          now: now.addingTimeInterval(6)), .poor, "stale fix")
    }

    func testBlockers() {
        XCTAssertEqual(DriveBlocker.evaluate(motionAvailable: true, gpsStatus: .good, speedMps: 10, serverUnreachable: false), [])
        XCTAssertEqual(DriveBlocker.evaluate(motionAvailable: true, gpsStatus: .good, speedMps: nil, serverUnreachable: false), [.tooSlow])
        XCTAssertEqual(DriveBlocker.evaluate(motionAvailable: false, gpsStatus: .denied, speedMps: 3.9, serverUnreachable: true),
                       [.motionUnavailable, .locationDenied, .tooSlow, .serverUnreachable])
        XCTAssertEqual(DriveBlocker.evaluate(motionAvailable: true, gpsStatus: .searching, speedMps: 4, serverUnreachable: false), [.poorGPS])
    }
}

final class MotionSampleBufferTests: XCTestCase {
    func testBufferKeepsAtMostTwoSecondsAndDownsamples() {
        var buffer = MotionSampleBuffer(duration: 2)
        for i in 0..<300 {
            buffer.append(MotionSample(t: Double(i) / 50, accelMagnitudeG: Double(i), rotationRateRadS: 0))
        }
        guard let first = buffer.samples.first, let last = buffer.samples.last else {
            return XCTFail("buffer empty")
        }
        XCTAssertLessThanOrEqual(last.t - first.t, 2.0 + 1e-9)
        XCTAssertTrue((99...101).contains(buffer.samples.count), "≈2 s at 50 Hz")

        let points = buffer.downsampled(stride: 5)
        XCTAssertTrue((20...21).contains(points.count), "≈10 Hz")
        XCTAssertEqual(points.last, last, "ends at the newest sample")
        XCTAssertTrue(zip(points, points.dropFirst()).allSatisfy { $1.t > $0.t })
    }

    func testMagnitudeFromComponents() {
        let sample = MotionSample(t: 0, acceleration: (3, 4, 0), rotation: (0, 0, 2))
        XCTAssertEqual(sample.accelMagnitudeG, 5, accuracy: 1e-12)
        XCTAssertEqual(sample.rotationRateRadS, 2, accuracy: 1e-12)
    }
}
