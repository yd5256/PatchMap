//
//  Evidence.swift
//  PotholeMesh
//
//  Mirrors the backend `EvidenceIn`. Encoded with snake_case keys and ISO-8601 dates.
//

import Foundation

nonisolated enum EvidenceType: String, Codable, Sendable {
    case impact
    case cleanCrossing = "clean_crossing"
}

nonisolated struct EvidencePayload: Codable, Hashable, Sendable {
    var deviceId: String
    var type: EvidenceType
    var latitude: Double
    var longitude: Double
    var timestamp: Date
    var speedMps: Double?
    var gpsAccuracyM: Double?
    // Impact-only fields.
    var impactScore: Double?
    var peakAcceleration: Double?
    var peakJerk: Double?
    var rotationRate: Double?
    // Clean-crossing only.
    var roadDefectId: Int?
    var isSimulated: Bool

    static func impact(
        deviceId: String,
        latitude: Double,
        longitude: Double,
        timestamp: Date,
        speedMps: Double?,
        gpsAccuracyM: Double?,
        impactScore: Double,
        peakAcceleration: Double?,
        peakJerk: Double?,
        rotationRate: Double?,
        isSimulated: Bool
    ) -> EvidencePayload {
        EvidencePayload(
            deviceId: deviceId, type: .impact,
            latitude: latitude, longitude: longitude, timestamp: timestamp,
            speedMps: speedMps, gpsAccuracyM: gpsAccuracyM,
            impactScore: impactScore, peakAcceleration: peakAcceleration,
            peakJerk: peakJerk, rotationRate: rotationRate,
            roadDefectId: nil, isSimulated: isSimulated
        )
    }

    static func cleanCrossing(
        deviceId: String,
        roadDefectId: Int,
        latitude: Double,
        longitude: Double,
        timestamp: Date,
        speedMps: Double?,
        gpsAccuracyM: Double?,
        isSimulated: Bool
    ) -> EvidencePayload {
        EvidencePayload(
            deviceId: deviceId, type: .cleanCrossing,
            latitude: latitude, longitude: longitude, timestamp: timestamp,
            speedMps: speedMps, gpsAccuracyM: gpsAccuracyM,
            impactScore: nil, peakAcceleration: nil, peakJerk: nil, rotationRate: nil,
            roadDefectId: roadDefectId, isSimulated: isSimulated
        )
    }
}
