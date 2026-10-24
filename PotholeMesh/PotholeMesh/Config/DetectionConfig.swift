//
//  DetectionConfig.swift
//  PotholeMesh
//
//  Single source of every on-device sensing constant (Requirement 15.1, 17.1).
//  Values match the design; tests may construct a modified copy.
//

import Foundation

nonisolated struct DetectionConfig: Equatable, Sendable {
    static let standard = DetectionConfig()

    // MARK: Motion sampling

    /// Device-motion sample rate (Hz).
    var sampleHz: Double = 50
    /// Rolling window for μ/σ and the raw-motion ring buffer (s).
    var windowSeconds: Double = 2
    /// Rate the Drive chart is downsampled to (Hz).
    var chartHz: Double = 10

    // MARK: Impact candidate gate

    /// Floor for σ so a smooth road doesn't produce runaway z-scores (g).
    var sigmaFloorG: Double = 0.03
    /// Minimum deviation z = (m − μ) / max(σ, sigmaFloorG).
    var zThreshold: Double = 4.0
    /// Minimum peak acceleration magnitude (g).
    var minPeakG: Double = 0.35
    /// Minimum jerk (g/s).
    var jerkThresholdGps: Double = 8.0
    /// Rotation above this looks like phone handling, not a road impact (rad/s).
    var maxRotationRadS: Double = 3.0
    /// Minimum known speed for impacts and clean crossings (m/s, ~9 mph).
    var minSpeedMps: Double = 4.0
    /// Worst acceptable GPS horizontal accuracy (m).
    var maxHorizontalAccuracyM: Double = 20
    /// Oldest acceptable location fix (s).
    var maxFixAgeSeconds: Double = 5
    /// Minimum time between emitted impact events (s).
    var cooldownSeconds: Double = 2.0
    /// Capture length after the gate trips (s).
    var captureSeconds: Double = 0.25
    /// Duration is measured while m exceeds μ + durationSigmaMultiplier·σ.
    var durationSigmaMultiplier: Double = 2

    // MARK: Impact score (n(x, lo, hi) bounds and weights)

    /// Upper bound for the z term (lower bound is `zThreshold`).
    var scoreZUpper: Double = 12
    /// Upper bound for the jerk term (lower bound is `jerkThresholdGps`), g/s.
    var scoreJerkUpper: Double = 40
    /// Upper bound for the peak term (lower bound is `minPeakG`), g.
    var scorePeakUpper: Double = 2.5
    /// Bounds for the duration term (s).
    var scoreDurationLower: Double = 0.02
    var scoreDurationUpper: Double = 0.20
    /// Upper bound for the speed term (lower bound is `minSpeedMps`), m/s.
    var scoreSpeedUpper: Double = 20
    /// Rotation penalty: lower bound (upper bound is `maxRotationRadS`), rad/s.
    var scoreRotationLower: Double = 0.5
    /// Maximum fraction of the score removed by the rotation penalty.
    var scoreRotationPenalty: Double = 0.3

    var weightZ: Double = 0.35
    var weightJerk: Double = 0.25
    var weightPeak: Double = 0.20
    var weightDuration: Double = 0.10
    var weightSpeed: Double = 0.10

    // MARK: Clean crossings

    /// Entering this distance of a defect starts an encounter (m).
    var cleanCrossingRadiusM: Double = 12
    /// Leaving beyond this distance ends an encounter (m). Also the impact-suppression radius.
    var exitRadiusM: Double = 20
    /// A disarmed encounter re-arms beyond this distance (m).
    var resetRadiusM: Double = 60
    /// Encounters longer than this end without a crossing (s).
    var maxEncounterSeconds: Double = 30

    // MARK: Derived

    /// Samples between chart points (50 Hz / 10 Hz = 5).
    var chartStride: Int { max(1, Int((sampleHz / chartHz).rounded())) }
}
