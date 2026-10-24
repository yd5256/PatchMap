//
//  ImpactDetector.swift
//  PotholeMesh
//
//  Pure, deterministic impact detection (Requirement 15.3–15.6, 15.11). Turns device-motion
//  samples plus the latest location fix into discrete impact events using a rolling 2 s
//  baseline, a multi-condition candidate gate, a short peak capture, and a transparent
//  0–100 score. Time comes only from the inputs, never from the system clock, so the
//  detector runs in unit tests with synthetic samples.
//

import Foundation

/// Inputs that accompany each motion sample.
nonisolated struct ImpactContext: Equatable, Sendable {
    /// Latest accepted location fix, if any.
    let fix: LocationFix?
    /// Wall-clock time of the sample, used for fix freshness and the event date.
    let now: Date
}

/// One detected road impact.
nonisolated struct ImpactEvent: Equatable, Sendable {
    /// Motion time (`MotionSample.t`) of the triggering sample.
    let triggerTime: TimeInterval
    /// Wall-clock time of the triggering sample.
    let date: Date
    /// The location fix that passed the gate.
    let fix: LocationFix
    /// z-score of the triggering sample against the pre-event baseline.
    let z: Double
    /// Peak |userAcceleration| during the capture (g).
    let peakG: Double
    /// Peak |jerk| during the capture (g/s).
    let peakJerkGps: Double
    /// Peak |rotationRate| during the capture (rad/s).
    let peakRotationRadS: Double
    /// Time during the capture that m exceeded μ + 2σ of the baseline (s).
    let durationSeconds: Double
    /// Relative intensity in [0, 100].
    let score: Int
}

nonisolated struct ImpactDetector: Sendable {
    let config: DetectionConfig

    /// Samples from the most recent `windowSeconds`, used for μ and σ.
    private var window: MotionSampleBuffer
    private var previousMagnitude: Double?
    private var lastEventTime: TimeInterval?
    private var capture: Capture?

    /// State of an in-progress capture after the gate trips.
    private struct Capture: Sendable {
        let startTime: TimeInterval
        let date: Date
        let fix: LocationFix
        let speedMps: Double
        let z: Double
        let durationThresholdG: Double
        var peakG: Double
        var peakJerk: Double
        var peakRotation: Double
        var samplesAboveThreshold: Int

        mutating func add(m: Double, jerk: Double, r: Double) {
            peakG = max(peakG, m)
            peakJerk = max(peakJerk, abs(jerk))
            peakRotation = max(peakRotation, r)
            if m > durationThresholdG { samplesAboveThreshold += 1 }
        }
    }

    init(config: DetectionConfig = .standard) {
        self.config = config
        window = MotionSampleBuffer(duration: config.windowSeconds)
    }

    /// True while a capture is collecting peaks.
    var isCapturing: Bool { capture != nil }

    /// Clears all history, as if no sample had been seen.
    mutating func reset() {
        self = ImpactDetector(config: config)
    }

    /// Processes one sample. Returns an event when a capture completes, otherwise nil.
    mutating func process(_ sample: MotionSample, context: ImpactContext) -> ImpactEvent? {
        let m = sample.accelMagnitudeG
        let r = sample.rotationRateRadS
        let jerk = previousMagnitude.map { (m - $0) * config.sampleHz } ?? 0
        previousMagnitude = m

        defer { window.append(sample) }

        if var active = capture {
            active.add(m: m, jerk: jerk, r: r)
            capture = active
            return completeIfDue(at: sample.t)
        }

        // Baseline from the window preceding this sample.
        guard let baseline = baseline() else { return nil }
        let z = (m - baseline.mean) / max(baseline.sigma, config.sigmaFloorG)

        guard let fix = context.fix,
              fix.isFresh(at: context.now, config: config),
              let speed = fix.speedMps, speed >= config.minSpeedMps,
              z >= config.zThreshold,
              m >= config.minPeakG,
              jerk >= config.jerkThresholdGps,
              r <= config.maxRotationRadS,
              cooldownElapsed(at: sample.t) else {
            return nil
        }

        var started = Capture(
            startTime: sample.t,
            date: context.now,
            fix: fix,
            speedMps: speed,
            z: z,
            durationThresholdG: baseline.mean + config.durationSigmaMultiplier * baseline.sigma,
            peakG: 0, peakJerk: 0, peakRotation: 0,
            samplesAboveThreshold: 0
        )
        started.add(m: m, jerk: jerk, r: r)
        capture = started
        return completeIfDue(at: sample.t)
    }

    // MARK: Scoring

    /// `n(x, lo, hi) = clamp((x − lo)/(hi − lo), 0, 1)`.
    static func normalized(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        guard hi > lo else { return x >= hi ? 1 : 0 }
        return min(max((x - lo) / (hi - lo), 0), 1)
    }

    /// Transparent impact score (Requirement 15.6), an integer in [0, 100].
    static func score(
        z: Double,
        peakJerkGps: Double,
        peakG: Double,
        durationSeconds: Double,
        speedMps: Double,
        peakRotationRadS: Double,
        config: DetectionConfig = .standard
    ) -> Int {
        let c = config
        let raw = c.weightZ * normalized(z, c.zThreshold, c.scoreZUpper)
            + c.weightJerk * normalized(peakJerkGps, c.jerkThresholdGps, c.scoreJerkUpper)
            + c.weightPeak * normalized(peakG, c.minPeakG, c.scorePeakUpper)
            + c.weightDuration * normalized(durationSeconds, c.scoreDurationLower, c.scoreDurationUpper)
            + c.weightSpeed * normalized(speedMps, c.minSpeedMps, c.scoreSpeedUpper)
        let penalty = 1 - c.scoreRotationPenalty
            * normalized(peakRotationRadS, c.scoreRotationLower, c.maxRotationRadS)
        let value = (100 * raw * penalty).rounded()
        return Int(min(max(value, 0), 100))
    }

    // MARK: Private

    private func baseline() -> (mean: Double, sigma: Double)? {
        let samples = window.samples
        guard let first = samples.first, let last = samples.last,
              last.t - first.t >= config.minBaselineSeconds else {
            return nil
        }
        let count = Double(samples.count)
        let mean = samples.reduce(0) { $0 + $1.accelMagnitudeG } / count
        let variance = samples.reduce(0) { acc, s in
            let d = s.accelMagnitudeG - mean
            return acc + d * d
        } / count
        return (mean, variance.squareRoot())
    }

    private func cooldownElapsed(at t: TimeInterval) -> Bool {
        guard let lastEventTime else { return true }
        return t - lastEventTime >= config.cooldownSeconds
    }

    private mutating func completeIfDue(at t: TimeInterval) -> ImpactEvent? {
        guard let active = capture,
              t - active.startTime >= config.captureSeconds - Self.timeEpsilon else {
            return nil
        }
        capture = nil
        lastEventTime = active.startTime
        let duration = Double(active.samplesAboveThreshold) / config.sampleHz
        return ImpactEvent(
            triggerTime: active.startTime,
            date: active.date,
            fix: active.fix,
            z: active.z,
            peakG: active.peakG,
            peakJerkGps: active.peakJerk,
            peakRotationRadS: active.peakRotation,
            durationSeconds: duration,
            score: Self.score(
                z: active.z,
                peakJerkGps: active.peakJerk,
                peakG: active.peakG,
                durationSeconds: duration,
                speedMps: active.speedMps,
                peakRotationRadS: active.peakRotation,
                config: config
            )
        )
    }

    /// Tolerance for accumulated floating-point sample times.
    private static let timeEpsilon = 1e-9
}
