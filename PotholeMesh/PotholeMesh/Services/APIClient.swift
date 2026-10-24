//
//  APIClient.swift
//  PotholeMesh
//
//  Async URLSession wrapper for the five backend endpoints. Every call throws only
//  `APIError` (Requirement 10.5–10.7, 19.7).
//

import Foundation
import os

nonisolated enum APIError: Error, Equatable, Sendable {
    /// The server could not be reached (bad URL, no route, connection refused, ...).
    case unreachable
    /// No response arrived within `AppConfig.requestTimeout`.
    case timeout
    /// The response status was outside 2xx.
    case http(status: Int)
    /// The response body could not be decoded.
    case decoding

    /// Network errors and 5xx are worth retrying; 4xx and decoding errors are not.
    var isRetryable: Bool {
        switch self {
        case .unreachable, .timeout: true
        case .http(let status): (500...599).contains(status)
        case .decoding: false
        }
    }

    /// True for connectivity failures (unreachable or timeout).
    var isConnectivity: Bool {
        self == .unreachable || self == .timeout
    }
}

protocol APIClientProtocol: AnyObject {
    func health() async throws(APIError)
    func postEvidence(_ payload: EvidencePayload) async throws(APIError) -> IngestResponse
    func defects() async throws(APIError) -> [RoadDefect]
    func defect(id: Int) async throws(APIError) -> RoadDefect
    func resetDemo() async throws(APIError)
}

final class URLSessionAPIClient: APIClientProtocol {
    private static let logger = Logger(subsystem: "com.hackachusetts.PotholeMesh", category: "APIClient")

    private let session: URLSession
    private let baseURLProvider: () -> URL?
    private let decoder = JSONCoding.makeDecoder()
    private let encoder = JSONCoding.makeEncoder()

    /// - Parameter baseURLProvider: Read on every request so a server URL change in the
    ///   Demo tab applies to all later requests. Defaults to `AppConfig.baseURL()`.
    init(session: URLSession? = nil, baseURLProvider: (() -> URL?)? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = AppConfig.requestTimeout
            configuration.timeoutIntervalForResource = AppConfig.requestTimeout
            configuration.waitsForConnectivity = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
        self.baseURLProvider = baseURLProvider ?? { AppConfig.baseURL() }
    }

    func health() async throws(APIError) {
        let response: StatusResponse = try await send("GET", path: "health")
        guard response.status == "ok" else { throw .decoding }
    }

    func postEvidence(_ payload: EvidencePayload) async throws(APIError) -> IngestResponse {
        let body: Data
        do {
            body = try encoder.encode(payload)
        } catch {
            Self.logger.error("Failed to encode evidence: \(String(describing: error), privacy: .public)")
            throw .decoding
        }
        return try await send("POST", path: "evidence", body: body)
    }

    func defects() async throws(APIError) -> [RoadDefect] {
        try await send("GET", path: "defects")
    }

    func defect(id: Int) async throws(APIError) -> RoadDefect {
        try await send("GET", path: "defects/\(id)")
    }

    func resetDemo() async throws(APIError) {
        let response: StatusResponse = try await send("POST", path: "demo/reset")
        guard response.status == "reset" else { throw .decoding }
    }

    // MARK: - Transport

    private func send<T: Decodable>(_ method: String, path: String, body: Data? = nil) async throws(APIError) -> T {
        guard let baseURL = baseURLProvider() else { throw .unreachable }
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = AppConfig.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw error.code == .timedOut ? .timeout : .unreachable
        } catch {
            throw .unreachable
        }

        guard let http = response as? HTTPURLResponse else { throw .unreachable }
        guard (200...299).contains(http.statusCode) else {
            throw .http(status: http.statusCode)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            Self.logger.error("Failed to decode \(method, privacy: .public) /\(path, privacy: .public): \(String(describing: error), privacy: .public)")
            throw .decoding
        }
    }
}
