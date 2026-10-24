//
//  CleanCrossingTracker.swift
//  PotholeMesh
//
//  Pure, deterministic clean-crossing detection (Requirement 17). Keeps one Encounter per
//  active defect and emits a CLEAN_CROSSING when the phone passes a known defect at speed
//  without feeling an impact:
//
//    Armed --(≤ 12 m)--> InEncounter --(> 20 m, no impact, fast, good GPS)--> Disarmed (emit)
//    InEncounter --(> 30 s)--> Disarmed (no emit)
//    Disarmed --(> 60 m)--> Armed
//
//  Time comes only from the injected `now` / `time` parameters; no sensors or networking.
//

import Foundation

/// Great-circle distance helpers (spherical Earth, matches the backend's haversine).
nonisolated enum Geo {
    static let earthRadiusM = 6_371_000.0

    static func haversineM(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let toRad = Double.pi / 180
        let dLat = (lat2 - lat1) * toRad
        let dLon = (lon2 - lon1) * toRad
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * toRad) * cos(lat2 * toRad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusM * asin(min(1, a.squareRoot()))
    }
}

/// The minimal defect info the tracker needs.
nonisolated struct TrackedDefect: Equatable, Sendable {
    let id: Int
    let latitude: Double
    let longitude: Double

    init(id: Int, latitude: Double, longitude: Double) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ defect: RoadDefect) {
        self.init(id: defect.id, latitude: defect.latitude, longitude: defect.longitude)
    }

    func distanceM(to fix: LocationFix) -> Double {
        Geo.haversineM(lat1: latitude, lon1: longitude, lat2: fix.latitude, lon2: fix.longitude)
    }
}

/// One detected clean crossing: the defect and the exit fix.
nonisolated struct CleanCrossingEvent: Equatable, Sendable {
    let roadDefectId: Int
    let fix: LocationFix
    let time: Date
}

nonisolated struct CleanCrossingTracker: Sendable {
    nonisolated enum Phase: Equatable, Sendable {
        case armed
        case inEncounter(start: Date, impactSeen: Bool)
        case disarmed
    }

    nonisolated struct Encounter: Equatable, Sendable {
        var defect: TrackedDefect
        var phase: Phase
    }

    let config: DetectionConfig
    /// Exactly one Encounter per active defect from the latest `update`, keyed by defect id.
    private(set) var encounters: [Int: Encounter] = [:]

    init(config: DetectionConfig = .standard) {
        self.config = config
    }

    func phase(for defectId: Int) -> Phase? {
        encounters[defectId]?.phase
    }

    mutating func reset() {
        encounters = [:]
    }

    /// Convenience for the app, which holds `RoadDefect`s from `DefectStore`.
    mutating func update(fix: LocationFix, activeDefects: [RoadDefect], now: Date) -> [CleanCrossingEvent] {
        update(fix: fix, activeDefects: activeDefects.map(TrackedDefect.init), now: now)
    }

    /// Advances every Encounter with the current fix and returns the crossings that completed,
    /// ordered by defect id.
    mutating func update(fix: LocationFix, activeDefects: [TrackedDefect], now: Date) -> [CleanCrossingEvent] {
        // Keep exactly one Encounter per active defect; new defects start Armed.
        var next: [Int: Encounter] = [:]
        for defect in activeDefects {
            var encounter = encounters[defect.id] ?? Encounter(defect: defect, phase: .armed)
            encounter.defect = defect  // the backend centroid can move
            next[defect.id] = encounter
        }

        var events: [CleanCrossingEvent] = []
        for id in next.keys.sorted() {
            guard var encounter = next[id] else { continue }
            let distance = encounter.defect.distanceM(to: fix)

            switch encounter.phase {
            case .armed:
                if distance <= config.cleanCrossingRadiusM {
                    encounter.phase = .inEncounter(start: now, impactSeen: false)
                }

            case let .inEncounter(start, impactSeen):
                if now.timeIntervalSince(start) > config.maxEncounterSeconds {
                    encounter.phase = .disarmed
                } else if distance > config.exitRadiusM {
                    encounter.phase = .disarmed
                    if !impactSeen && qualifiesAsExit(fix) {
                        events.append(CleanCrossingEvent(roadDefectId: id, fix: fix, time: now))
                    }
                }

            case .disarmed:
                if distance > config.resetRadiusM {
                    encounter.phase = .armed
                }
            }
            next[id] = encounter
        }

        encounters = next
        return events
    }

    /// Marks `impactSeen` on every InEncounter Encounter whose defect is within `exitRadiusM`
    /// of the impact position. All other Encounters are left unchanged. `time` is accepted
    /// for symmetry with `update` and is not needed by the rule.
    mutating func noteImpact(at fix: LocationFix, time: Date) {
        for (id, encounter) in encounters {
            guard case let .inEncounter(start, _) = encounter.phase,
                  encounter.defect.distanceM(to: fix) <= config.exitRadiusM else {
                continue
            }
            encounters[id]?.phase = .inEncounter(start: start, impactSeen: true)
        }
    }

    /// Exit fix must be fast enough (impact detection was armed) with usable accuracy.
    private func qualifiesAsExit(_ fix: LocationFix) -> Bool {
        guard let speed = fix.speedMps, speed >= config.minSpeedMps else { return false }
        return fix.horizontalAccuracyM > 0 && fix.horizontalAccuracyM <= config.maxHorizontalAccuracyM
    }
}
