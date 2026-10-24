//
//  EvidenceUploader.swift
//  PotholeMesh
//
//  Uploads real (Drive) evidence immediately and keeps a small in-memory FIFO retry
//  queue for retryable failures (Requirement 18, 19.3). The queue is never written to
//  disk (9.7). Server-side dedupe makes retries idempotent, since a queued payload keeps
//  its original timestamp.
//

import Foundation
import Observation
import os

@Observable
final class EvidenceUploader {
    private static let logger = Logger(subsystem: "com.hackachusetts.PotholeMesh", category: "EvidenceUploader")

    /// Maximum queued payloads; the oldest is dropped when a 51st would be added.
    static let maxQueueSize = 50
    static let initialRetryDelay: Duration = .seconds(2)
    static let maxRetryDelay: Duration = .seconds(30)

    struct QueuedEvidence: Identifiable, Equatable {
        let id: UUID
        let payload: EvidencePayload
    }

    /// Payloads accepted with a 2xx status since launch.
    private(set) var uploadedCount = 0
    /// Retry queue, oldest first. In memory only.
    private(set) var queue: [QueuedEvidence] = []
    /// Delay before the next retry: 2 s, doubling per consecutive retryable failure, capped at 30 s.
    private(set) var retryDelay: Duration = initialRetryDelay
    /// The error from the most recent post or retry, or nil if it succeeded.
    private(set) var lastError: APIError?

    @ObservationIgnored private let api: APIClientProtocol
    @ObservationIgnored private let autoRetry: Bool
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private var retryTask: Task<Void, Never>?

    /// - Parameters:
    ///   - autoRetry: When false, no background retry loop runs; tests drive `retryOnce()`.
    ///   - sleep: Injected delay used by the retry loop.
    init(
        api: APIClientProtocol,
        autoRetry: Bool = true,
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.api = api
        self.autoRetry = autoRetry
        self.sleep = sleep
    }

    /// Current number of queued payloads (0–50).
    var pendingCount: Int { queue.count }

    /// True when the most recent upload failed because the server couldn't be reached.
    var lastUploadFailedConnectivity: Bool { lastError?.isConnectivity ?? false }

    /// Fire-and-forget: posts the payload right away.
    func upload(_ payload: EvidencePayload) {
        Task { await self.submit(payload) }
    }

    /// Posts the payload once, with no delay or batching. Retryable failures are queued.
    func submit(_ payload: EvidencePayload) async {
        do {
            _ = try await api.postEvidence(payload)
            uploadedCount += 1
            lastError = nil
        } catch {
            lastError = error
            if error.isRetryable {
                enqueue(payload)
            } else {
                Self.logger.error("Dropping evidence after non-retryable error: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Retries the oldest queued payload once.
    func retryOnce() async {
        guard let item = queue.first else { return }
        do {
            _ = try await api.postEvidence(item.payload)
            remove(item.id)
            uploadedCount += 1
            lastError = nil
            retryDelay = Self.initialRetryDelay
        } catch {
            lastError = error
            if error.isRetryable {
                retryDelay = min(retryDelay * 2, Self.maxRetryDelay)
            } else {
                Self.logger.error("Dropping queued evidence after non-retryable error: \(String(describing: error), privacy: .public)")
                remove(item.id)
            }
        }
    }

    // MARK: Queue

    private func enqueue(_ payload: EvidencePayload) {
        queue.append(QueuedEvidence(id: UUID(), payload: payload))
        if queue.count > Self.maxQueueSize {
            queue.removeFirst(queue.count - Self.maxQueueSize)
        }
        startRetryLoopIfNeeded()
    }

    private func remove(_ id: UUID) {
        queue.removeAll { $0.id == id }
    }

    private func startRetryLoopIfNeeded() {
        guard autoRetry, retryTask == nil, !queue.isEmpty else { return }
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.queue.isEmpty else { break }
                do {
                    try await self.sleep(self.retryDelay)
                } catch {
                    break // cancelled
                }
                await self.retryOnce()
            }
            self?.retryTask = nil
        }
    }
}
