//
//  AppConfig.swift
//  PotholeMesh
//
//  Single place for app-level networking constants (Requirement 10.2–10.4).
//

import Foundation

enum AppConfig {
    /// Default backend base URL. Works as-is in the iOS Simulator on the Mac running
    /// the backend. On a real iPhone, enter `http://<Mac LAN IP>:8000` in the Demo tab.
    static let defaultBaseURLString = "http://localhost:8000"

    /// `GET /defects` poll interval while the app is active.
    static let pollInterval: Duration = .seconds(2)

    /// Per-request timeout in seconds.
    static let requestTimeout: TimeInterval = 5

    /// Demo_Coordinate (Boston). The Map tab's initial camera centers here, and the
    /// Demo simulator places its virtual pothole here.
    static let demoLatitude = 42.35500
    static let demoLongitude = -71.06500

    /// `UserDefaults` key for the server URL override set from the Demo tab.
    static let baseURLOverrideKey = "PotholeMesh.apiBaseURLOverride"

    /// The base URL string in effect: the stored override if present, else the default.
    static func baseURLString(defaults: UserDefaults = .standard) -> String {
        if let override = defaults.string(forKey: baseURLOverrideKey),
           !override.isEmpty {
            return override
        }
        return defaultBaseURLString
    }

    /// The base URL in effect, or nil if the configured string is not a usable http(s) URL.
    static func baseURL(defaults: UserDefaults = .standard) -> URL? {
        makeURL(from: baseURLString(defaults: defaults))
    }

    /// Persists a server URL override. Passing nil or a blank string clears it,
    /// which reverts to `defaultBaseURLString`.
    static func setBaseURLOverride(_ value: String?, defaults: UserDefaults = .standard) {
        let normalized = normalize(value ?? "")
        if normalized.isEmpty {
            defaults.removeObject(forKey: baseURLOverrideKey)
        } else {
            defaults.set(normalized, forKey: baseURLOverrideKey)
        }
    }

    /// Trims whitespace and trailing slashes, and adds `http://` when no scheme is given.
    static func normalize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return "" }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "http://" + text
        }
        return text
    }

    static func makeURL(from string: String) -> URL? {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host() != nil else {
            return nil
        }
        return url
    }
}
