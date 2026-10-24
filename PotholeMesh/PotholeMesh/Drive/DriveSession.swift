//
//  DriveSession.swift
//  PotholeMesh
//
//  Orchestrates one on-device sensing session (Requirement 14, 19.5, 19.6): owns the
//  motion and location services, publishes the Drive tab's status, keeps a ~10 Hz
//  chart series drawn from the 2 s in-memory motion buffer, and gates every piece of
//  evidence on a fresh, accurate fix and granted location permission.
//
//  `ImpactDetector` runs in `handle(sample:)` and `CleanCrossingTracker` in `handle(fix:)`;
//  both hand payloads to `submitEvidence(_:)`.
//

import Foundation
import Observation
import os

// MARK: - Status types

nonisolated enum GPSStatus: Equatable, Sendable {
    case good
    case poor
    case searching
    case denied

    /// Requirement 14.2: denied if authorization is denied/restricted; searching if no fix
    /// has arrived; poor if the latest accepted fix is stale or inaccurate, or only
    /// rejected fixes have arrived; good otherwise.
    static func evaluate(
        authorization: LocationAuthorization,
        latestFix: LocationFix?,
        hasReceivedAnyFix: Bool,
        now: Date,
        config: DetectionConfig = .standard
    ) -> GPSStatus {
        if authorization.isDeniedOrRestricted { return .denied }
        guard let latestFix else { return hasReceivedAnyFix ? .poor : .searching }
        return latestFix.isFresh(at: now, config: config) ? .good : .poor
    }

    var displayName: String {
        switch self {
        case .good: "Good"
        case .poor: "Poor"
        case .searching: "Searching"
        case .denied: "Denied"
        }
    }
}

/// Conditions that stop sensing from producing evidence (Requirement 14.4).
nonisolated enum DriveBlocker: String, CaseIterable, Identifiable, Sendable {
    case motionUnavailable
    case locationDenied
    case poorGPS
    case tooSlow
    case serverUnreachable

    var id: Self { self }

    static func evaluate(
        motionAvailable: Bool,
        gpsStatus: GPSStatus,
        speedMps: Double?,
        serverUnreachable: Bool,
        config: DetectionConfig = .standard
    ) -> [DriveBlocker] {
        var blockers: [DriveBlocker] = []
        if !motionAvailable { blockers.append(.motionUnavailable) }
        switch gpsStatus {
        case .denied: blockers.append(.locationDenied)
        case .searching, .poor: blockers.append(.poorGPS)
        case .good: break
        }
        if (speedMps ?? -1) < config.minSpeedMps { blockers.append(.tooSlow) }
        if serverUnreachable { blockers.append(.serverUnreachable) }
        return blockers
    }

    var title: String {
        switch self {
        case .motionUnavailable: "Motion sensors unavailable"
        case .locationDenied: "Location access denied"
        case .poorGPS: "Poor GPS"
        case .tooSlow: "Too slow"
        case .serverUnreachable: "Server unreachable"
        }
    }

    var detail: String {
        switch self {
        case .motionUnavailable: "This device can't report motion, so impacts can't be detected."
        case .locationDenied: "Allow location While Using the App so impacts can be tagged."
        case .poorGPS: "Waiting for an accurate location fix. Sensing resumes automatically."
        case .tooSlow: "Impacts are only detected above about 9 mph."
        case .serverUnreachable: "Evidence is queued and will retry automatically."
        }
    }

    var systemImage: String {
        switch self {
        case .motionUnavailable: "gyroscope"
        case .locationDenied: "location.slash"
        case .poorGPS: "location.magnifyingglass"
        case .tooSlow: "tortoise"
        case .serverUnreachable: "wifi.slash"
        }
    }
}

/// One chart point: acceleration magnitude, positioned relative to the newest sample.
nonisolated struct AccelerationPoint: Identifiable, Equatable, Sendable {
    /// Seconds before the newest buffered sample (≤ 0).
    let offsetSeconds: Double
    let magnitudeG: Double
    var id: Double { offsetSeconds }
}

// MARK: - Session

@Observable
final class DriveSession {
    private static let logger = Logger(subsystem: "com.hackachusetts.PotholeMesh", category: "DriveSession")

    private(set) var isActive = false
    private(set) var startedAt: Date?
    private(set) var stoppedAt: Date?
    /// Ticks once a second while active so duration and GPS freshness stay current.
    private(set) var now: Date
    /// Impacts detected in the current session by `ImpactDetector`.
    private(set) var impactCount = 0
    /// ~10 Hz magnitude series drawn only from the 2 s in-memory motion buffer.
    private(set) var chartPoints: [AccelerationPoint] = []

    @ObservationIgnored let config: DetectionConfig
    @ObservationIgnored let location: LocationService
    @ObservationIgnored private let motion: MotionService
    @ObservationIgnored private let uploader: EvidenceUploader
    /// Active defects for the clean-crossing tracker.
    @ObservationIgnored private let defectStore: DefectStore
    @ObservationIgnored private let deviceId: String
    @ObservationIgnored private let currentDate: () -> Date
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var samplesSinceChartUpdate = 0
    @ObservationIgnored private var detector: ImpactDetector
    @ObservationIgnored private var tracker: CleanCrossingTracker

    init(
        uploader: EvidenceUploader,
        defectStore: DefectStore,
        deviceId: String,
        config: DetectionConfig = .standard,
        currentDate: @escaping () -> Date = Date.init
    ) {
        self.uploader = uploader
        self.defectStore = defectStore
        self.deviceId = deviceId
        self.config = config
        self.currentDate = currentDate
        self.now = currentDate()
        motion = MotionService(config: config)
        location = LocationService(config: config, now: currentDate)
        detector = ImpactDetector(config: config)
        tracker = CleanCrossingTracker(config: config)
    }

    // MARK: Published status

    var isMotionAvailable: Bool { motion.isAvailable }
    var authorization: LocationAuthorization { location.authorization }
    var latestFix: LocationFix? { location.latestFix }
    var speedMps: Double? { latestFix?.speedMps }

    var gpsStatus: GPSStatus {
        GPSStatus.evaluate(
            authorization: location.authorization,
            latestFix: location.latestFix,
            hasReceivedAnyFix: location.hasReceivedAnyFix,
            now: now,
            config: config
        )
    }

    /// Seconds since START SENSING (frozen at STOP).
    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, (stoppedAt ?? now).timeIntervalSince(startedAt))
    }

    var uploadedCount: Int { uploader.uploadedCount }
    var pendingCount: Int { uploader.pendingCount }

    /// Every blocking condition that currently holds.
    var blockers: [DriveBlocker] {
        DriveBlocker.evaluate(
            motionAvailable: motion.isAvailable,
            gpsStatus: gpsStatus,
            speedMps: speedMps,
            serverUnreachable: uploader.lastUploadFailedConnectivity,
            config: config
        )
    }

    /// Evidence may only be produced with permission and a fresh fix ≤ 20 m (19.5).
    /// Evaluated against the real clock, so it resumes as soon as a good fix arrives (19.6).
    var canProduceEvidence: Bool {
        isActive && GPSStatus.evaluate(
            authorization: location.authorization,
            latestFix: location.latestFix,
            hasReceivedAnyFix: location.hasReceivedAnyFix,
            now: currentDate(),
            config: config
        ) == .good
    }

    // MARK: Controls

    func toggle() {
        if isActive { stop() } else { start() }
    }

    /// Starts sensing. Does nothing when device motion is unavailable (14.5).
    func start() {
        guard !isActive, motion.isAvailable else { return }
        detector.reset()
        tracker.reset()
        let started = motion.start { [weak self] sample in
            self?.handle(sample: sample)
        }
        guard started else { return }

        location.onFix = { [weak self] fix in
            self?.handle(fix: fix)
        }
        location.start()

        let date = currentDate()
        now = date
        startedAt = date
        stoppedAt = nil
        impactCount = 0
        chartPoints = []
        samplesSinceChartUpdate = 0
        isActive = true
        startTicking()
    }

    func stop() {
        guard isActive else { return }
        tickTask?.cancel()
        tickTask = nil
        motion.stop()
        location.stop()
        location.onFix = nil
        now = currentDate()
        stoppedAt = now
        chartPoints = []
        isActive = false
    }

    // MARK: Evidence

    /// The single gate every Drive payload passes through. Returns false (and drops the
    /// payload) while GPS is searching/poor or location is denied.
    @discardableResult
    func submitEvidence(_ payload: EvidencePayload) -> Bool {
        guard canProduceEvidence else {
            Self.logger.debug("Evidence suppressed: no fresh, accurate fix")
            return false
        }
        uploader.upload(payload)
        return true
    }

    // MARK: Sensor input

    private func handle(sample: MotionSample) {
        let context = ImpactContext(fix: location.latestFix, now: currentDate())
        if let event = detector.process(sample, context: context) {
            handle(impact: event)
        }
        samplesSinceChartUpdate += 1
        if samplesSinceChartUpdate >= config.chartStride {
            samplesSinceChartUpdate = 0
            updateChart()
        }
    }

    /// Requirement 14.7, 14.8: one IMPACT payload from the gating fix, count bump (which
    /// drives the Drive tab's light haptic and counter animation), and tracker suppression.
    private func handle(impact event: ImpactEvent) {
        let fix = event.fix
        let payload = EvidencePayload.impact(
            deviceId: deviceId,
            latitude: fix.latitude,
            longitude: fix.longitude,
            timestamp: event.date,
            speedMps: fix.speedMps,
            gpsAccuracyM: fix.horizontalAccuracyM,
            impactScore: Double(event.score),
            peakAcceleration: event.peakG,
            peakJerk: event.peakJerkGps,
            rotationRate: event.peakRotationRadS,
            isSimulated: false
        )
        submitEvidence(payload)
        impactCount += 1
        tracker.noteImpact(at: fix, time: event.date)
        Self.logger.debug("Impact detected, score \(event.score)")
    }

    private func handle(fix: LocationFix) {
        now = currentDate()
        let crossings = tracker.update(fix: fix, activeDefects: defectStore.defects, now: now)
        for crossing in crossings {
            let exit = crossing.fix
            let payload = EvidencePayload.cleanCrossing(
                deviceId: deviceId,
                roadDefectId: crossing.roadDefectId,
                latitude: exit.latitude,
                longitude: exit.longitude,
                timestamp: exit.timestamp,
                speedMps: exit.speedMps,
                gpsAccuracyM: exit.horizontalAccuracyM,
                isSimulated: false
            )
            submitEvidence(payload)
            Self.logger.debug("Clean crossing for defect \(crossing.roadDefectId)")
        }
    }

    private func updateChart() {
        let samples = motion.buffer.downsampled(stride: config.chartStride)
        guard let newest = samples.last else {
            chartPoints = []
            return
        }
        chartPoints = samples.map {
            AccelerationPoint(offsetSeconds: $0.t - newest.t, magnitudeG: $0.accelMagnitudeG)
        }
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self else { return }
                self.now = self.currentDate()
            }
        }
    }
}
