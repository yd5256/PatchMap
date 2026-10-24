//
//  DriveTabView.swift
//  PotholeMesh
//
//  Drive tab: one START / STOP SENSING button, session status rows, a live acceleration
//  chart, and banners for every condition that blocks evidence (Requirement 14).
//

import SwiftUI
import UIKit

struct DriveTabView: View {
    @Environment(DriveSession.self) private var session

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(visibleBlockers) { blocker in
                        BlockerBanner(blocker: blocker)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    sensingButton
                    statusCard

                    if session.isActive {
                        DriveCard(title: "Acceleration") {
                            AccelerationChart(points: session.chartPoints,
                                              windowSeconds: session.config.windowSeconds,
                                              minPeakG: session.config.minPeakG)
                        }
                        .transition(.opacity)
                    }

                    privacyNote
                }
                .padding()
                .animation(.easeInOut(duration: 0.25), value: visibleBlockers)
                .animation(.easeInOut(duration: 0.25), value: session.isActive)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Drive")
        }
        .sensoryFeedback(.impact(weight: .light), trigger: session.impactCount) { _, new in new > 0 }
    }

    /// Banners shown right now. Motion-unavailable and location-denied are always shown
    /// (14.5, 14.6); the rest only while sensing (14.4).
    private var visibleBlockers: [DriveBlocker] {
        session.blockers.filter { blocker in
            switch blocker {
            case .motionUnavailable, .locationDenied: true
            case .poorGPS, .tooSlow, .serverUnreachable: session.isActive
            }
        }
    }

    // MARK: Sections

    private var sensingButton: some View {
        Button {
            session.toggle()
        } label: {
            Label(session.isActive ? "STOP SENSING" : "START SENSING",
                  systemImage: session.isActive ? "stop.fill" : "dot.radiowaves.left.and.right")
                .font(.title3.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(session.isActive ? .red : .blue)
        .disabled(!session.isMotionAvailable)
        .accessibilityLabel(session.isActive ? "Stop sensing" : "Start sensing")
        .accessibilityHint(session.isActive
                           ? "Stops motion and location sensing"
                           : "Starts detecting road impacts with motion and location")
    }

    private var statusCard: some View {
        DriveCard(title: "Session") {
            VStack(spacing: 10) {
                StatusRow(title: "Sensing", systemImage: "waveform.path.ecg",
                          value: session.isActive ? "Active" : "Stopped",
                          color: session.isActive ? .green : .secondary)
                StatusRow(title: "GPS", systemImage: "location",
                          value: gpsText, color: gpsColor)
                StatusRow(title: "Speed", systemImage: "speedometer", value: speedText)
                StatusRow(title: "Duration", systemImage: "timer", value: durationText)
                StatusRow(title: "Impacts detected", systemImage: "exclamationmark.triangle",
                          value: "\(session.impactCount)")
                StatusRow(title: "Uploaded / pending", systemImage: "icloud.and.arrow.up",
                          value: "\(session.uploadedCount) / \(session.pendingCount)",
                          color: session.pendingCount > 0 ? .orange : .primary)
            }
        }
    }

    private var privacyNote: some View {
        Label("Only discrete impact and clean-crossing events are uploaded. Your route and raw motion never leave the phone.",
              systemImage: "hand.raised")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Formatting

    private var gpsText: String {
        if session.gpsStatus == .denied { return GPSStatus.denied.displayName }
        return session.isActive ? session.gpsStatus.displayName : "Off"
    }

    private var gpsColor: Color {
        guard session.isActive || session.gpsStatus == .denied else { return .secondary }
        switch session.gpsStatus {
        case .good: return .green
        case .poor, .searching: return .orange
        case .denied: return .red
        }
    }

    private var speedText: String {
        guard session.isActive, let speed = session.speedMps else { return "—" }
        return Measurement(value: speed, unit: UnitSpeed.metersPerSecond)
            .formatted(.measurement(width: .abbreviated, usage: .general,
                                    numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    private var durationText: String {
        Duration.seconds(session.elapsed.rounded(.down))
            .formatted(.time(pattern: .minuteSecond))
    }
}

// MARK: - Building blocks

private struct StatusRow: View {
    let title: String
    let systemImage: String
    let value: String
    var color: Color = .primary

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
                .contentTransition(.numericText())
                .animation(.snappy, value: value)
        }
        .font(.subheadline)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

private struct BlockerBanner: View {
    let blocker: DriveBlocker

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: blocker.systemImage)
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(blocker.title)
                    .font(.headline)
                Text(blocker.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if blocker == .locationDenied, let settingsURL {
                    Link("Open Settings", destination: settingsURL)
                        .font(.footnote.weight(.semibold))
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var settingsURL: URL? {
        URL(string: UIApplication.openSettingsURLString)
    }
}

private struct DriveCard<Content: View>: View {
    var title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.headline)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview {
    let api = URLSessionAPIClient()
    let uploader = EvidenceUploader(api: api)
    DriveTabView()
        .environment(DriveSession(uploader: uploader, defectStore: DefectStore(api: api), deviceId: "preview"))
}
