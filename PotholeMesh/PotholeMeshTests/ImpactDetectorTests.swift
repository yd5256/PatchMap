//
//  ImpactDetectorTests.swift
//  PotholeMeshTests
//
//  Property 12: iOS impact detector. Synthetic 50 Hz samples, synthetic location fixes,
//  and injected time only; no sensors, permissions, or network.
//
//  **Validates: Requirements 15.7, 15.8, 15.9, 15.10, 21.3, 21.6**
//

import XCTest
@testable import PotholeMesh

/// Deterministic seeded generator (SplitMix64) so noise is identical on every run.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Standard normal value via Box–Muller.
    mutating func gaussian() -> Double {
        let u1 = max(Double.random(in: 0..<1, using: &self), .leastNonzeroMagnitude)
        let u2 = Double.random(in: 0..<1, using: &self)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// A spike injected at a given sample index.
private struct Spike {
    let index: Int
    let magnitudeG: Double
    var rotationRadS: Double = 0.5
}

private enum Signal {
    static let sampleHz = DetectionConfig.standard.sampleHz
    static let baseDate = Date(timeIntervalSince1970: 1_767_268_800)
    static let noiseMeanG = 0.05
    static let noiseSigmaG = 0.02
    static let baseRotationRadS = 0.2

    /// Index of the first sample after a 2 s baseline at 50 Hz.
    static let afterBaseline = 100

    /// Runs `count` samples of seeded 0.02 g noise (plus optional spikes) through a fresh
    /// detector. Every sample gets a fix timestamped at that sample's time, so the fix is
    /// always fresh; `speedMps` and `accuracyM` control the gate.
    static func run(
        count: Int,
        spikes: [Spike] = [],
        speedMps: Double? = 10,
        accuracyM: Double = 5,
        seed: UInt64 = 42,
        config: DetectionConfig = .standard
    ) -> [ImpactEvent] {
        var rng = SeededGenerator(seed: seed)
        var detector = ImpactDetector(config: config)
        let spikesByIndex = Dictionary(uniqueKeysWithValues: spikes.map { ($0.index, $0) })
        var events: [ImpactEvent] = []

        for i in 0..<count {
            let t = Double(i) / sampleHz
            let now = baseDate.addingTimeInterval(t)
            let noise = max(0, noiseMeanG + noiseSigmaG * rng.gaussian())
            let spike = spikesByIndex[i]
            let sample = MotionSample(
                t: t,
                accelMagnitudeG: spike?.magnitudeG ?? noise,
                rotationRateRadS: spike?.rotationRadS ?? baseRotationRadS
            )
            let fix = LocationFix(
                latitude: 42.355, longitude: -71.065,
                horizontalAccuracyM: accuracyM, speedMps: speedMps, timestamp: now
            )
            if let event = detector.process(sample, context: ImpactContext(fix: fix, now: now)) {
                events.append(event)
            }
        }
        return events
    }
}

final class ImpactDetectorTests: XCTestCase {
    // MARK: Flat signal

    func testFlatNoiseNeverTriggersAcrossSeeds() {
        for seed in UInt64(1)...10 {
            let events = Signal.run(count: 3_000, seed: seed)  // 60 s of driving per seed
            XCTAssertTrue(events.isEmpty, "seed \(seed) produced \(events.count) false impacts")
        }
    }

    // MARK: Single spike

    func testSingleSpikeAfterBaselineTriggersExactlyOnce() throws {
        let events = Signal.run(
            count: 400,
            spikes: [Spike(index: Signal.afterBaseline, magnitudeG: 1.5)]
        )
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.triggerTime, 2.0, accuracy: 1e-9)
        XCTAssertEqual(event.peakG, 1.5, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(event.z, DetectionConfig.standard.zThreshold)
        XCTAssertGreaterThanOrEqual(event.peakJerkGps, DetectionConfig.standard.jerkThresholdGps)
        XCTAssertEqual(event.fix.speedMps, 10)
        XCTAssertTrue((0...100).contains(event.score))
    }

    func testSingleSpikeTriggersAtExactlyMinimumSpeed() {
        let events = Signal.run(
            count: 400,
            spikes: [Spike(index: Signal.afterBaseline, magnitudeG: 1.5)],
            speedMps: DetectionConfig.standard.minSpeedMps
        )
        XCTAssertEqual(events.count, 1)
    }

    func testSpikeAcrossSeedsTriggersExactlyOnce() {
        for seed in UInt64(1)...10 {
            let events = Signal.run(
                count: 400,
                spikes: [Spike(index: Signal.afterBaseline, magnitudeG: 1.5)],
                seed: seed
            )
            XCTAssertEqual(events.count, 1, "seed \(seed)")
        }
    }

    // MARK: Gate rejections

    func testSpikeBelowMinimumSpeedDoesNotTrigger() {
        for speed in [0.0, 2.0, 3.99] {
            let events = Signal.run(
                count: 400,
                spikes: [Spike(index: Signal.afterBaseline, magnitudeG: 1.5)],
                speedMps: speed
            )
            XCTAssertTrue(events.isEmpty, "speed \(speed)")
        }
    }

    func testSpikeWithUnknownSpeedDoesNotTrigger() {
        let events = Signal.run(
            count: 400,
            spikes: [Spike(index: Signal.afterBaseline, magnitudeG: 1.5)],
            speedMps: nil
        )
        XCTAssertTrue(events.isEmpty)
    }

    func testSpikeWithHighRotationDoesNotTrigger() {
        for rotation in [3.01, 3.5, 6.0] {
            let events = Signal.run(
                count: 400,
                spikes: [Spike(index: Signal.afterBaseline, magnitudeG: 1.5, rotationRadS: rotation)]
            )
            XCTAssertTrue(events.isEmpty, "rotation \(rotation)")
        }
    }

    func testSpikeWithPoorGPSAccuracyDoesNotTrigger() {
        let events = Signal.run(
            count: 400,
            spikes: [Spike(index: Signal.afterBaseline, magnitudeG: 1.5)],
            accuracyM: 25
        )
        XCTAssertTrue(events.isEmpty)
    }

    func testSecondSpikeInsideCooldownDoesNotTrigger() {
        // Spikes 1.0 s apart; cooldown is 2.0 s.
        let spikes = [
            Spike(index: Signal.afterBaseline, magnitudeG: 1.5),
            Spike(index: Signal.afterBaseline + 50, magnitudeG: 1.5),
        ]
        XCTAssertEqual(Signal.run(count: 500, spikes: spikes).count, 1)

        // Control: the same second spike passes every other gate, so only the cooldown
        // suppresses it.
        var shortCooldown = DetectionConfig.standard
        shortCooldown.cooldownSeconds = 0.5
        XCTAssertEqual(Signal.run(count: 500, spikes: spikes, config: shortCooldown).count, 2)
    }

    func testSpikesAfterCooldownTriggerSeparately() {
        let spikes = [
            Spike(index: Signal.afterBaseline, magnitudeG: 1.5),
            Spike(index: Signal.afterBaseline + 150, magnitudeG: 1.5),  // 3 s later
        ]
        XCTAssertEqual(Signal.run(count: 600, spikes: spikes).count, 2)
    }

    // MARK: Score

    func testScoreIsInRangeAndNonDecreasingWithAmplitude() {
        let amplitudes = [0.5, 0.8, 1.0, 1.5, 2.0, 2.5, 3.0, 5.0]
        var previous = Int.min
        for amplitude in amplitudes {
            let events = Signal.run(
                count: 300,
                spikes: [Spike(index: Signal.afterBaseline, magnitudeG: amplitude)]
            )
            XCTAssertEqual(events.count, 1, "amplitude \(amplitude)")
            guard let score = events.first?.score else { continue }
            XCTAssertTrue((0...100).contains(score), "amplitude \(amplitude) score \(score)")
            XCTAssertGreaterThanOrEqual(score, previous, "amplitude \(amplitude)")
            previous = score
        }
    }

    func testStaticScoreStaysInRangeOverInputGrid() {
        let zs = [-5.0, 0, 4, 8, 12, 50]
        let jerks = [0.0, 8, 24, 40, 500]
        let peaks = [0.0, 0.35, 1.5, 2.5, 10]
        let durations = [0.0, 0.02, 0.1, 0.2, 2]
        let speeds = [0.0, 4, 12, 20, 60]
        let rotations = [0.0, 0.5, 1.5, 3, 10]
        for z in zs { for j in jerks { for p in peaks { for d in durations { for s in speeds { for r in rotations {
            let score = ImpactDetector.score(
                z: z, peakJerkGps: j, peakG: p, durationSeconds: d,
                speedMps: s, peakRotationRadS: r
            )
            XCTAssertTrue((0...100).contains(score), "score \(score) for z=\(z) j=\(j) p=\(p) d=\(d) s=\(s) r=\(r)")
        } } } } } }
    }

    func testStaticScoreExtremes() {
        let maxed = ImpactDetector.score(
            z: 12, peakJerkGps: 40, peakG: 2.5, durationSeconds: 0.2,
            speedMps: 20, peakRotationRadS: 0
        )
        XCTAssertEqual(maxed, 100)
        let floor = ImpactDetector.score(
            z: 4, peakJerkGps: 8, peakG: 0.35, durationSeconds: 0.02,
            speedMps: 4, peakRotationRadS: 0
        )
        XCTAssertEqual(floor, 0)
    }
}
