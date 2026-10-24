//
//  MapMarkerTests.swift
//  PotholeMeshTests
//
//  Map marker sizing and fade-out reconciliation (Requirement 11.2, 11.4, 11.6).
//

import XCTest
@testable import PotholeMesh

private func defect(_ id: Int, state: DefectState = .suspected) -> RoadDefect {
    let date = Date(timeIntervalSince1970: 1_767_268_800)
    return RoadDefect(
        id: id, latitude: 42.355, longitude: -71.065, state: state,
        confidence: 0.5, severity: 58, positiveObservationCount: 1,
        positiveUniqueDeviceCount: 1, cleanCrossingCount: 0, cleanUniqueDeviceCount: 0,
        firstSeen: date, lastSeen: date, createdAt: date, updatedAt: date
    )
}

@MainActor
final class MapMarkerTests: XCTestCase {
    func testMarkerDiametersStrictlyIncreaseBySeverityBand() {
        let low = DefectMarker.diameter(for: .low)
        let moderate = DefectMarker.diameter(for: .moderate)
        let high = DefectMarker.diameter(for: .high)
        XCTAssertLessThan(low, moderate)
        XCTAssertLessThan(moderate, high)
    }

    func testReconcileShowsExactlyOneMarkerPerIncomingDefectWithBackendValues() {
        let incoming = [defect(1), defect(2, state: .confirmed)]
        let result = MapMarkerReconciler.reconcile(current: [], incoming: incoming)
        XCTAssertEqual(result.items.map(\.defect), incoming)
        XCTAssertTrue(result.items.allSatisfy { !$0.isLeaving })
        XCTAssertEqual(result.newlyLeaving, [])
    }

    func testReconcileUpdatesStateInPlace() {
        let current = [MapMarkerItem(defect: defect(1), isLeaving: false)]
        let result = MapMarkerReconciler.reconcile(current: current, incoming: [defect(1, state: .confirmed)])
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items.first?.defect.state, .confirmed)
        XCTAssertEqual(result.newlyLeaving, [])
    }

    func testDroppedDefectFadesThenIsRemoved() {
        let current = [
            MapMarkerItem(defect: defect(1), isLeaving: false),
            MapMarkerItem(defect: defect(2), isLeaving: false),
        ]
        let result = MapMarkerReconciler.reconcile(current: current, incoming: [defect(1)])
        XCTAssertEqual(result.newlyLeaving, [2])
        XCTAssertEqual(result.items.first { $0.id == 2 }?.isLeaving, true)

        // A later poll doesn't restart the fade for an already leaving marker.
        let again = MapMarkerReconciler.reconcile(current: result.items, incoming: [defect(1)])
        XCTAssertEqual(again.newlyLeaving, [])

        let removed = MapMarkerReconciler.removeLeaving(id: 2, from: again.items)
        XCTAssertEqual(removed.map(\.id), [1])
    }

    func testReappearingDefectIsNotRemoved() {
        let leaving = [MapMarkerItem(defect: defect(2), isLeaving: true)]
        let back = MapMarkerReconciler.reconcile(current: leaving, incoming: [defect(2)])
        XCTAssertEqual(back.items, [MapMarkerItem(defect: defect(2), isLeaving: false)])
        XCTAssertEqual(MapMarkerReconciler.removeLeaving(id: 2, from: back.items).count, 1)
    }
}
