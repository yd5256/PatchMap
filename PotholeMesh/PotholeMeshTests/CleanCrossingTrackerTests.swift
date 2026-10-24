//
//  CleanCrossingTrackerTests.swift
//  PotholeMeshTests
//
//  Property 13: iOS clean-crossing tracker. Synthetic fixes along straight or oscillating
//  paths with injected time only; no location services, permissions, or network.
//
//  **Validates: Requirements 17.2, 17.3, 17.4, 17.5, 17.6, 17.8, 21.3, 21.6**
//

import XCTest
@testable import PotholeMesh

/// Local metric frame around a defect: `north` / `east` offsets in meters.
private enum Path {
    static let originLat = 42.355
    static let originLon = -71.065
    static let baseDate = Date(timeIntervalSince1970: 1_767_268_800)
    static let metersPerDegLat = Geo.earthRadiusM * .pi / 180

    static func coordinate(north: Double, east: Double = 0) -> (lat: Double, lon: Double) {
        let lat = originLat + north / metersPerDegLat
        let lon = originLon + east / (metersPerDegLat * cos(originLat * .pi / 180))
        return (lat, lon)
    }

    static func defect(id: Int, north: Double = 0, east: Double = 0) -> TrackedDefect {
        let c = coordinate(north: north, east: east)
        return TrackedDefect(id: id, latitude: c.lat, longitude: c.lon)
    }

    static func fix(
        north: Double,
        east: Double = 0,
        second: Double,
        speedMps: Double? = 10,
        accuracyM: Double = 5
    ) -> LocationFix {
        let c = coordinate(north: north, east: east)
        return LocationFix(
            latitude: c.lat, longitude: c.lon,
            horizontalAccuracyM: accuracyM, speedMps: speedMps,
            timestamp: baseDate.addingTimeInterval(second)
        )
    }

    /// North offsets from `from` to `to` (inclusive) in `step` meter increments.
    static func line(from: Double, to: Double, step: Double = 5) -> [Double] {
        Array(stride(from: from, through: to, by: to >= from ? step : -step))
    }
}

/// Drives a tracker along a sequence of fixes, one per second starting at `startSecond`.
private struct Drive {
    var tracker = CleanCrossingTracker()
    var defects: [TrackedDefect]
    var second: Double = 0
    private(set) var events: [CleanCrossingEvent] = []

    init(defects: [TrackedDefect]) {
        self.defects = defects
    }

    /// The most recent fix fed to the tracker.
    private(set) var lastFix: LocationFix?

    mutating func visit(
        _ norths: [Double],
        east: Double = 0,
        speedMps: Double? = 10,
        accuracyM: Double = 5,
        secondsPerFix: Double = 1
    ) {
        for north in norths {
            let fix = Path.fix(north: north, east: east, second: second,
                               speedMps: speedMps, accuracyM: accuracyM)
            events += tracker.update(fix: fix, activeDefects: defects, now: fix.timestamp)
            lastFix = fix
            second += secondsPerFix
        }
    }

    mutating func impact(north: Double, east: Double = 0) {
        let fix = Path.fix(north: north, east: east, second: second)
        tracker.noteImpact(at: fix, time: fix.timestamp)
    }
}

final class CleanCrossingTrackerTests: XCTestCase {
    // MARK: Straight passes

    func testStraightPassEmitsExactlyOne() throws {
        var drive = Drive(defects: [Path.defect(id: 7)])
        drive.visit(Path.line(from: -100, to: 100))

        XCTAssertEqual(drive.events.count, 1)
        let event = try XCTUnwrap(drive.events.first)
        XCTAssertEqual(event.roadDefectId, 7)
        // Emitted on the first fix beyond the 20 m exit radius (25 m north).
        let exitDistance = Path.defect(id: 7).distanceM(to: event.fix)
        XCTAssertGreaterThan(exitDistance, DetectionConfig.standard.exitRadiusM)
        XCTAssertEqual(exitDistance, 25, accuracy: 0.01)
        // The pass ends 100 m away, beyond the 60 m reset radius, so it has re-armed.
        XCTAssertEqual(drive.tracker.phase(for: 7), .armed)
    }

    func testStraightPassesWithinEntryRadiusEmitOneAndOutsideEmitNone() {
        for lateral in [0.0, 4, 8, 11.5] {
            var drive = Drive(defects: [Path.defect(id: 1)])
            drive.visit(Path.line(from: -100, to: 100), east: lateral)
            XCTAssertEqual(drive.events.count, 1, "lateral offset \(lateral) m")
        }
        for lateral in [13.0, 18, 30] {
            var drive = Drive(defects: [Path.defect(id: 1)])
            drive.visit(Path.line(from: -100, to: 100), east: lateral)
            XCTAssertTrue(drive.events.isEmpty, "lateral offset \(lateral) m")
        }
    }

    func testPassInEitherDirectionEmitsExactlyOne() {
        var drive = Drive(defects: [Path.defect(id: 1)])
        drive.visit(Path.line(from: 100, to: -100))
        XCTAssertEqual(drive.events.count, 1)
    }

    // MARK: Impact suppression

    func testImpactNearDefectSuppressesCrossing() {
        var drive = Drive(defects: [Path.defect(id: 1)])
        drive.visit(Path.line(from: -100, to: 0))
        drive.impact(north: 3)
        drive.visit(Path.line(from: 5, to: 100))
        XCTAssertTrue(drive.events.isEmpty)
    }

    func testImpactExactlyAtExitRadiusSuppressesCrossing() {
        var drive = Drive(defects: [Path.defect(id: 1)])
        drive.visit(Path.line(from: -100, to: 0))
        drive.impact(north: 0, east: DetectionConfig.standard.exitRadiusM - 0.01)
        drive.visit(Path.line(from: 5, to: 100))
        XCTAssertTrue(drive.events.isEmpty)
    }

    func testImpactFartherThanExitRadiusDoesNotSuppress() {
        var drive = Drive(defects: [Path.defect(id: 1)])
        drive.visit(Path.line(from: -100, to: 0))
        drive.impact(north: 0, east: 35)
        drive.visit(Path.line(from: 5, to: 100))
        XCTAssertEqual(drive.events.map(\.roadDefectId), [1])
    }

    func testImpactAtNearbyDefectSuppressesOnlyThatDefect() {
        // A at 0 m, B at 25 m north. At 15 m north both are InEncounter. The impact at
        // 22 m north is 22 m from A (> 20 m) and 3 m from B.
        var drive = Drive(defects: [Path.defect(id: 1), Path.defect(id: 2, north: 25)])
        drive.visit(Path.line(from: -100, to: 15))
        XCTAssertEqual(drive.tracker.phase(for: 1).map(isInEncounter), true)
        XCTAssertEqual(drive.tracker.phase(for: 2).map(isInEncounter), true)

        drive.impact(north: 22)
        drive.visit(Path.line(from: 20, to: 150))
        XCTAssertEqual(drive.events.map(\.roadDefectId), [1])
    }

    func testImpactBeforeEncounterDoesNotSuppress() {
        var drive = Drive(defects: [Path.defect(id: 1)])
        drive.visit(Path.line(from: -100, to: -40))
        drive.impact(north: -15)  // within 20 m of the defect, but the encounter is still Armed
        drive.visit(Path.line(from: -35, to: 100))
        XCTAssertEqual(drive.events.count, 1)
    }

    // MARK: Lingering and oscillation

    func testOscillatingWithinResetRadiusEmitsAtMostOne() {
        var drive = Drive(defects: [Path.defect(id: 1)])
        drive.visit(Path.line(from: -100, to: 0))
        for _ in 0..<6 {
            drive.visit([10, 25, 40, 55, 40, 25, 10, 0, -10, -25, -55, -25, -10, 0])
        }
        XCTAssertLessThanOrEqual(drive.events.count, 1)
        XCTAssertEqual(drive.events.count, 1)
    }

    func testLingeringStationaryNearDefectThenLeavingEmitsNone() {
        var drive = Drive(defects: [Path.defect(id: 1)])
        drive.visit(Path.line(from: -100, to: -10))
        drive.visit(Array(repeating: 0, count: 40))  // 40 s parked on the defect
        drive.visit(Path.line(from: 5, to: 50))
        XCTAssertTrue(drive.events.isEmpty)
    }

    // MARK: Exit quality

    func testSlowOrUnknownSpeedExitEmitsNone() {
        for speed in [nil, 0.0, 2.0, 3.99] as [Double?] {
            var drive = Drive(defects: [Path.defect(id: 1)])
            drive.visit(Path.line(from: -100, to: 15))
            drive.visit([25], speedMps: speed)
            XCTAssertTrue(drive.events.isEmpty, "exit speed \(String(describing: speed))")
            XCTAssertEqual(drive.tracker.phase(for: 1), .disarmed)
        }
    }

    func testExitAtExactlyMinimumSpeedEmits() {
        var drive = Drive(defects: [Path.defect(id: 1)])
        drive.visit(Path.line(from: -100, to: 15))
        drive.visit([25], speedMps: DetectionConfig.standard.minSpeedMps)
        XCTAssertEqual(drive.events.count, 1)
    }

    func testPoorAccuracyExitEmitsNone() {
        for accuracy in [0.0, 20.5, 30] {
            var drive = Drive(defects: [Path.defect(id: 1)])
            drive.visit(Path.line(from: -100, to: 15))
            drive.visit([25], accuracyM: accuracy)
            XCTAssertTrue(drive.events.isEmpty, "exit accuracy \(accuracy)")
        }
    }

    // MARK: Encounter timeout

    func testEncounterLongerThanThirtySecondsEmitsNone() {
        var drive = Drive(defects: [Path.defect(id: 1)])
        drive.visit(Path.line(from: -100, to: -15))
        // Crawl from -10 m to +20 m over 31 s, then exit at speed.
        drive.visit(Path.line(from: -10, to: 20, step: 1), speedMps: 1)
        drive.visit(Path.line(from: 25, to: 100))
        XCTAssertTrue(drive.events.isEmpty)
    }

    func testEncounterJustUnderThirtySecondsStillEmits() {
        var drive = Drive(defects: [Path.defect(id: 1)])
        drive.visit(Path.line(from: -100, to: -15))
        // Enter at -10 m, stay in range, and exit at speed 29 s after entering.
        drive.visit(Path.line(from: -10, to: 18, step: 1), speedMps: 1)
        drive.visit(Path.line(from: 25, to: 100))
        XCTAssertEqual(drive.events.count, 1)
    }

    // MARK: Re-arm

    func testReArmsBeyondResetRadiusAndEmitsAgainOnNextPass() {
        var drive = Drive(defects: [Path.defect(id: 1)])
        drive.visit(Path.line(from: -100, to: 55))
        XCTAssertEqual(drive.events.count, 1)
        XCTAssertEqual(drive.tracker.phase(for: 1), .disarmed)

        drive.visit([65])
        XCTAssertEqual(drive.tracker.phase(for: 1), .armed)

        drive.visit(Path.line(from: 60, to: -100))
        XCTAssertEqual(drive.events.map(\.roadDefectId), [1, 1])
    }

    func testDoesNotReArmAtOrWithinResetRadius() {
        var drive = Drive(defects: [Path.defect(id: 1)])
        drive.visit(Path.line(from: -100, to: 55))
        drive.visit([59, 55])
        XCTAssertEqual(drive.tracker.phase(for: 1), .disarmed)
        drive.visit(Path.line(from: 50, to: -55))
        XCTAssertEqual(drive.events.count, 1)
    }

    // MARK: Defect set

    func testKeepsExactlyOneEncounterPerActiveDefect() {
        var drive = Drive(defects: [Path.defect(id: 1), Path.defect(id: 2, north: 500)])
        drive.visit([-100])
        XCTAssertEqual(Set(drive.tracker.encounters.keys), [1, 2])

        drive.defects = [Path.defect(id: 2, north: 500)]
        drive.visit([-95])
        XCTAssertEqual(Set(drive.tracker.encounters.keys), [2])
    }

    func testMultipleDefectsOnOnePassEachEmitOnce() {
        var drive = Drive(defects: [Path.defect(id: 1), Path.defect(id: 2, north: 200)])
        drive.visit(Path.line(from: -100, to: 300))
        XCTAssertEqual(drive.events.map(\.roadDefectId), [1, 2])
    }

    // MARK: Helpers

    private func isInEncounter(_ phase: CleanCrossingTracker.Phase) -> Bool {
        if case .inEncounter = phase { return true }
        return false
    }
}
