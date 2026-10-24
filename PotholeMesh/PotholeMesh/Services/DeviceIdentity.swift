//
//  DeviceIdentity.swift
//  PotholeMesh
//
//  The only identity in the system: a random per-install UUID (Requirement 9.1–9.3).
//

import Foundation

enum DeviceIdentity {
    static let storageKey = "PotholeMesh.deviceId"

    /// Returns the stored device id, generating and storing a new random UUID on first use.
    static func deviceId(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: storageKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: storageKey)
        return fresh
    }
}
