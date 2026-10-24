//
//  DefectStore.swift
//  PotholeMesh
//
//  Polls `GET /defects` every 2 s while the app is active. The Map tab and the
//  Drive clean-crossing tracker both read from this one published list
//  (Requirement 10.8–10.11, 19.1, 19.2).
//

import Foundation
import Observation
import os

enum ConnectionStatus: Equatable {
    /// No poll has completed yet.
    case unknown
    /// The most recent poll succeeded.
    case connected
    /// The most recent poll failed.
    case failed(APIError)

    var isConnected: Bool { self == .connected }

    /// True when the most recent poll failed because the server couldn't be reached.
    var isUnreachable: Bool {
        if case .failed(let error) = self { return error.isConnectivity }
        return false
    }
}

@Observable
final class DefectStore {
    private static let logger = Logger(subsystem: "com.hackachusetts.PotholeMesh", category: "DefectStore")

    /// Active (non-resolved) defects from the last successful poll.
    private(set) var defects: [RoadDefect] = []
    /// Time of the last successful poll.
    private(set) var lastRefresh: Date?
    private(set) var connectionStatus: ConnectionStatus = .unknown

    @ObservationIgnored private let api: APIClientProtocol
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(api: APIClientProtocol, pollInterval: Duration = AppConfig.pollInterval, now: @escaping () -> Date = Date.init) {
        self.api = api
        self.pollInterval = pollInterval
        self.now = now
    }

    var isPolling: Bool { pollTask != nil }

    func defect(id: Int) -> RoadDefect? {
        defects.first { $0.id == id }
    }

    /// Starts the single poll loop. Calling it while already polling does nothing.
    func startPolling() {
        guard pollTask == nil else { return }
        let interval = pollInterval
        pollTask = Task { [weak self] in
            let clock = ContinuousClock()
            var next = clock.now
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                next = next.advanced(by: interval)
                // If a slow request overran the interval, don't fire a burst to catch up.
                if next < clock.now { next = clock.now }
                do {
                    try await clock.sleep(until: next)
                } catch {
                    return // cancelled
                }
            }
        }
    }

    /// Stops the poll loop; no further `GET /defects` requests are issued until restarted.
    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Performs one poll. On failure the last published list and refresh time are kept.
    func refresh() async {
        do {
            let fetched = try await api.defects()
            defects = fetched
            lastRefresh = now()
            connectionStatus = .connected
        } catch {
            if error == .decoding {
                Self.logger.error("GET /defects returned an undecodable body; keeping previous data")
            }
            connectionStatus = .failed(error)
        }
    }
}
