//
//  MotionService.swift
//  PotholeMesh
//
//  Owns the app's single `CMMotionManager` and delivers device-motion samples at
//  `DetectionConfig.sampleHz` on the main queue (Requirement 15.2). Raw motion is
//  kept only in a 2 s in-memory ring buffer and never written to disk (9.5).
//

import CoreMotion
import Foundation

/// One processed device-motion sample.
nonisolated struct MotionSample: Equatable, Sendable {
    /// Monotonic sample time in seconds (CoreMotion timestamp, seconds since boot).
    let t: TimeInterval
    /// |userAcceleration| in g (gravity excluded, orientation-independent).
    let accelMagnitudeG: Double
    /// |rotationRate| in rad/s.
    let rotationRateRadS: Double

    init(t: TimeInterval, accelMagnitudeG: Double, rotationRateRadS: Double) {
        self.t = t
        self.accelMagnitudeG = accelMagnitudeG
        self.rotationRateRadS = rotationRateRadS
    }

    init(t: TimeInterval, acceleration: (x: Double, y: Double, z: Double), rotation: (x: Double, y: Double, z: Double)) {
        self.t = t
        accelMagnitudeG = (acceleration.x * acceleration.x + acceleration.y * acceleration.y
            + acceleration.z * acceleration.z).squareRoot()
        rotationRateRadS = (rotation.x * rotation.x + rotation.y * rotation.y
            + rotation.z * rotation.z).squareRoot()
    }
}

/// In-memory buffer holding only samples from the most recent `duration` seconds.
nonisolated struct MotionSampleBuffer: Sendable {
    let duration: TimeInterval
    private(set) var samples: [MotionSample] = []

    init(duration: TimeInterval) {
        self.duration = duration
    }

    var isEmpty: Bool { samples.isEmpty }

    /// Appends a sample and drops every sample older than `duration` before it.
    mutating func append(_ sample: MotionSample) {
        samples.append(sample)
        let cutoff = sample.t - duration
        if let firstKept = samples.firstIndex(where: { $0.t > cutoff }), firstKept > 0 {
            samples.removeFirst(firstKept)
        }
    }

    mutating func removeAll() {
        samples.removeAll()
    }

    /// Every `stride`-th sample, ending at the newest one, oldest first.
    func downsampled(stride step: Int) -> [MotionSample] {
        guard !samples.isEmpty else { return [] }
        let step = max(1, step)
        return Swift.stride(from: samples.count - 1, through: 0, by: -step)
            .reversed()
            .map { samples[$0] }
    }
}

final class MotionService {
    let config: DetectionConfig
    /// The only `CMMotionManager` in the app.
    private let manager = CMMotionManager()
    /// Raw samples from the last `windowSeconds`, in memory only.
    private(set) var buffer: MotionSampleBuffer
    private(set) var isRunning = false

    init(config: DetectionConfig = .standard) {
        self.config = config
        buffer = MotionSampleBuffer(duration: config.windowSeconds)
    }

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    /// Starts 50 Hz device-motion updates on the main queue.
    /// Returns false (and starts nothing) when device motion is unavailable.
    @discardableResult
    func start(onSample: @escaping (MotionSample) -> Void) -> Bool {
        guard manager.isDeviceMotionAvailable else { return false }
        guard !isRunning else { return true }
        buffer.removeAll()
        manager.deviceMotionUpdateInterval = 1 / config.sampleHz
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let a = motion.userAcceleration
            let r = motion.rotationRate
            let sample = MotionSample(
                t: motion.timestamp,
                acceleration: (a.x, a.y, a.z),
                rotation: (r.x, r.y, r.z)
            )
            self.buffer.append(sample)
            onSample(sample)
        }
        isRunning = true
        return true
    }

    /// Stops updates and discards the buffered raw motion.
    func stop() {
        manager.stopDeviceMotionUpdates()
        buffer.removeAll()
        isRunning = false
    }
}
