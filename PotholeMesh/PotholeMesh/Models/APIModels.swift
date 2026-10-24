//
//  APIModels.swift
//  PotholeMesh
//
//  Response envelopes and the shared JSON coders (snake_case + ISO-8601).
//

import Foundation

nonisolated struct Transition: Codable, Hashable, Sendable {
    let from: DefectState
    let to: DefectState
}

/// Mirrors the backend `IngestResult`.
nonisolated struct IngestResponse: Codable, Hashable, Sendable {
    let evidenceId: Int
    let duplicate: Bool
    let created: Bool
    let transition: Transition?
    let defect: RoadDefect
}

/// `{"status": "ok"}` from `GET /health`, `{"status": "reset"}` from `POST /demo/reset`.
nonisolated struct StatusResponse: Codable, Hashable, Sendable {
    let status: String
}

nonisolated enum JSONCoding {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

    /// Parses ISO-8601 date-times with or without fractional seconds.
    /// The backend currently sends second precision with a `Z` suffix.
    static func parseDate(_ text: String) -> Date? {
        if let date = try? whole.parse(text) { return date }
        if let date = try? fractional.parse(text) { return date }
        return nil
    }

    static func formatDate(_ date: Date) -> String {
        date.formatted(fractional)
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Invalid ISO-8601 date: \(text)")
            }
            return date
        }
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatDate(date))
        }
        return encoder
    }
}
