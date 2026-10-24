//
//  RoadDefect.swift
//  PotholeMesh
//
//  Mirrors the backend `DefectOut`. Values are displayed as returned; the app
//  never recomputes state, confidence, or severity.
//

import SwiftUI

nonisolated enum DefectState: String, Codable, Sendable, CaseIterable {
    case suspected = "SUSPECTED"
    case confirmed = "CONFIRMED"
    case likelyRepaired = "LIKELY_REPAIRED"
    case resolved = "RESOLVED"

    var displayName: String {
        switch self {
        case .suspected: "Suspected"
        case .confirmed: "Confirmed"
        case .likelyRepaired: "Likely repaired"
        case .resolved: "Resolved"
        }
    }

    /// Shared state color for map markers, the detail sheet, and the Demo status card.
    var color: Color {
        switch self {
        case .suspected: .orange
        case .confirmed: .red
        case .likelyRepaired: .teal
        case .resolved: .gray
        }
    }

    var systemImage: String {
        switch self {
        case .suspected: "exclamationmark"
        case .confirmed: "exclamationmark.triangle.fill"
        case .likelyRepaired: "wrench.and.screwdriver.fill"
        case .resolved: "checkmark.circle.fill"
        }
    }
}

/// Severity bands: low < 40 ≤ moderate < 70 ≤ high.
nonisolated enum SeverityBand: String, Sendable, CaseIterable, Comparable {
    case low, moderate, high

    init(severity: Double) {
        if severity >= 70 {
            self = .high
        } else if severity >= 40 {
            self = .moderate
        } else {
            self = .low
        }
    }

    var displayName: String {
        switch self {
        case .low: "Low"
        case .moderate: "Moderate"
        case .high: "High"
        }
    }

    private var rank: Int {
        switch self {
        case .low: 0
        case .moderate: 1
        case .high: 2
        }
    }

    static func < (lhs: SeverityBand, rhs: SeverityBand) -> Bool {
        lhs.rank < rhs.rank
    }
}

nonisolated struct RoadDefect: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let latitude: Double
    let longitude: Double
    let state: DefectState
    let confidence: Double
    let severity: Double
    let positiveObservationCount: Int
    let positiveUniqueDeviceCount: Int
    let cleanCrossingCount: Int
    let cleanUniqueDeviceCount: Int
    let firstSeen: Date
    let lastSeen: Date
    let createdAt: Date
    let updatedAt: Date

    var severityBand: SeverityBand { SeverityBand(severity: severity) }
}
