//
//  DemoEventLog.swift
//  PotholeMesh
//
//  Bounded, human-readable log of what the Demo simulator saw from the backend
//  (Requirement 13.6). Entries are derived only from ingest responses and
//  request failures; the simulator never invents defect state.
//

import Foundation

nonisolated struct DemoLogEntry: Identifiable, Hashable, Sendable {
    nonisolated enum Kind: Hashable, Sendable {
        case impact
        case cleanCrossing
        case created
        case transition(DefectState)
        case warning
        case info
    }

    let id: Int
    let date: Date
    let text: String
    let kind: Kind
}

nonisolated struct DemoEventLog: Sendable {
    /// Only the most recent entries are kept; the oldest are discarded first.
    static let capacity = 50

    /// Oldest first.
    private(set) var entries: [DemoLogEntry] = []
    private var nextId = 0

    var newestFirst: [DemoLogEntry] { entries.reversed() }
    var isEmpty: Bool { entries.isEmpty }

    mutating func append(_ text: String, kind: DemoLogEntry.Kind, date: Date = Date()) {
        entries.append(DemoLogEntry(id: nextId, date: date, text: text, kind: kind))
        nextId += 1
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    mutating func clear() {
        entries.removeAll()
    }

    /// Log lines for one ingest response, in display order:
    /// the vehicle's evidence, then "created", then any state transition.
    static func messages(
        for result: IngestResponse,
        payload: EvidencePayload,
        vehicle: String
    ) -> [(text: String, kind: DemoLogEntry.Kind)] {
        var lines: [(text: String, kind: DemoLogEntry.Kind)] = []
        let duplicateSuffix = result.duplicate ? " · duplicate ignored" : ""

        switch payload.type {
        case .impact:
            let score = Int((payload.impactScore ?? 0).rounded())
            lines.append(("\(vehicle): impact detected (score \(score))\(duplicateSuffix)", .impact))
        case .cleanCrossing:
            lines.append(("\(vehicle): clean crossing\(duplicateSuffix)", .cleanCrossing))
        }

        let defect = result.defect
        if result.created {
            lines.append(("Defect #\(defect.id) created · \(defect.state.displayName.lowercased())", .created))
        }
        if let transition = result.transition {
            lines.append(("Defect #\(defect.id) \(transition.to.displayName.lowercased())", .transition(transition.to)))
        }
        return lines
    }
}
