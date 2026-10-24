//
//  DefectMarker.swift
//  PotholeMesh
//
//  Map annotation content for one RoadDefect (Requirement 11.3–11.6).
//  Style comes only from the backend-returned state and severity.
//

import SwiftUI

/// One marker shown on the map. `isLeaving` is set when a successful poll no
/// longer contains the defect, so the marker can fade out before removal.
struct MapMarkerItem: Identifiable, Equatable {
    var defect: RoadDefect
    var isLeaving: Bool

    var id: Int { defect.id }
}

/// Pure reconciliation of the displayed markers against a new poll result.
enum MapMarkerReconciler {
    /// Returns the markers to display and the ids that just started leaving.
    /// Incoming defects are shown (and stop leaving if they come back); defects
    /// missing from `incoming` are kept, flagged as leaving, until removed.
    static func reconcile(
        current: [MapMarkerItem],
        incoming: [RoadDefect]
    ) -> (items: [MapMarkerItem], newlyLeaving: [Int]) {
        let incomingIds = Set(incoming.map(\.id))
        var items = incoming.map { MapMarkerItem(defect: $0, isLeaving: false) }
        var newlyLeaving: [Int] = []
        for item in current where !incomingIds.contains(item.id) {
            if !item.isLeaving { newlyLeaving.append(item.id) }
            items.append(MapMarkerItem(defect: item.defect, isLeaving: true))
        }
        return (items, newlyLeaving)
    }

    /// Removes a marker only if it is still leaving (it may have reappeared).
    static func removeLeaving(id: Int, from items: [MapMarkerItem]) -> [MapMarkerItem] {
        items.filter { !($0.id == id && $0.isLeaving) }
    }
}

struct DefectMarker: View {
    let defect: RoadDefect
    var isLeaving: Bool = false
    var isSelected: Bool = false

    /// Fade-out duration used before a dropped marker is removed.
    static let fadeOutDuration: Double = 0.6

    @State private var hasAppeared = false

    /// Three marker diameters, strictly increasing low → moderate → high.
    static func diameter(for band: SeverityBand) -> CGFloat {
        switch band {
        case .low: 28
        case .moderate: 38
        case .high: 50
        }
    }

    private var state: DefectState { defect.state }
    private var diameter: CGFloat { Self.diameter(for: defect.severityBand) }

    /// SUSPECTED is outlined; CONFIRMED and LIKELY_REPAIRED are solid.
    private var isOutlined: Bool { state == .suspected }
    private var fillColor: Color { isOutlined ? Color(.systemBackground) : state.color }
    private var iconColor: Color { isOutlined ? state.color : .white }

    var body: some View {
        ZStack {
            Circle()
                .fill(fillColor)
            Circle()
                .strokeBorder(state.color, lineWidth: isOutlined ? 3 : 2)
            Image(systemName: state.systemImage)
                .font(.system(size: diameter * 0.45, weight: .bold))
                .foregroundStyle(iconColor)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: state)
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        .scaleEffect(isSelected ? 1.2 : 1)
        .scaleEffect(hasAppeared && !isLeaving ? 1 : 0.4)
        .opacity(hasAppeared && !isLeaving ? 1 : 0)
        .animation(.spring(duration: 0.5), value: state)
        .animation(.spring(duration: 0.4), value: defect.severityBand)
        .animation(.spring(duration: 0.3), value: isSelected)
        .animation(.easeOut(duration: Self.fadeOutDuration), value: isLeaving)
        .animation(.easeOut(duration: 0.3), value: hasAppeared)
        .allowsHitTesting(!isLeaving)
        .onAppear { hasAppeared = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Defect \(defect.id), \(state.displayName)")
        .accessibilityValue(
            "Confidence \(Int((defect.confidence * 100).rounded())) percent, "
                + "\(defect.severityBand.displayName) severity"
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows defect details")
    }
}

#Preview {
    let date = Date()
    let make = { (id: Int, state: DefectState, severity: Double) in
        RoadDefect(
            id: id, latitude: 0, longitude: 0, state: state, confidence: 0.7,
            severity: severity, positiveObservationCount: 3, positiveUniqueDeviceCount: 3,
            cleanCrossingCount: 0, cleanUniqueDeviceCount: 0,
            firstSeen: date, lastSeen: date, createdAt: date, updatedAt: date
        )
    }
    HStack(spacing: 20) {
        DefectMarker(defect: make(1, .suspected, 30))
        DefectMarker(defect: make(2, .confirmed, 55))
        DefectMarker(defect: make(3, .likelyRepaired, 80))
    }
    .padding()
}
