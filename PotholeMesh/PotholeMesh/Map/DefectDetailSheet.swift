//
//  DefectDetailSheet.swift
//  PotholeMesh
//
//  Bottom sheet for one RoadDefect (Requirement 11.8, 11.9). Every value is
//  read from the DefectStore entry with the same id after each poll; if the
//  defect drops out of the active list, the last known values stay visible.
//

import SwiftUI

struct DefectDetailSheet: View {
    let defectId: Int

    @Environment(DefectStore.self) private var store
    @State private var lastKnown: RoadDefect

    init(defect: RoadDefect) {
        defectId = defect.id
        _lastKnown = State(initialValue: defect)
    }

    private var liveDefect: RoadDefect? { store.defect(id: defectId) }
    private var defect: RoadDefect { liveDefect ?? lastKnown }
    private var isActive: Bool { liveDefect != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !isActive {
                    Label("No longer active. Showing the last known values.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    confidenceCard
                    severityCard
                }
                statsGrid
                evidenceBar
                timesCard
            }
            .padding()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
        .onChange(of: liveDefect) { _, newValue in
            if let newValue { lastKnown = newValue }
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Defect #\(defect.id)")
                .font(.title2.bold())
            Spacer()
            StatePill(state: defect.state)
        }
    }

    private var confidenceCard: some View {
        StatCard(title: "Confidence") {
            Gauge(value: min(max(defect.confidence, 0), 1)) {
                Text("Confidence")
            } currentValueLabel: {
                Text(Self.percent(defect.confidence))
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(defect.state.color)
            .animation(.easeInOut, value: defect.confidence)
            .accessibilityLabel("Confidence")
            .accessibilityValue(Self.percent(defect.confidence))
        }
    }

    private var severityCard: some View {
        StatCard(title: "Severity") {
            VStack(alignment: .leading, spacing: 2) {
                Text(defect.severity, format: .number.precision(.fractionLength(0)))
                    .font(.title.bold().monospacedDigit())
                    .contentTransition(.numericText(value: defect.severity))
                Text("\(defect.severityBand.displayName) · of 100")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var statsGrid: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                countCard("Impact devices (P)", defect.positiveUniqueDeviceCount)
                countCard("Impact reports (O)", defect.positiveObservationCount)
            }
            GridRow {
                countCard("Clean devices (N)", defect.cleanUniqueDeviceCount)
                countCard("Clean crossings (C)", defect.cleanCrossingCount)
            }
        }
    }

    private func countCard(_ title: String, _ value: Int) -> some View {
        StatCard(title: title) {
            Text(value, format: .number)
                .font(.title2.bold().monospacedDigit())
                .contentTransition(.numericText(value: Double(value)))
                .accessibilityLabel(title)
                .accessibilityValue("\(value)")
        }
    }

    private var evidenceBar: some View {
        let positive = defect.positiveObservationCount
        let clean = defect.cleanCrossingCount
        return StatCard(title: "Evidence") {
            VStack(alignment: .leading, spacing: 8) {
                EvidenceSplitBar(positive: positive, clean: clean)
                    .frame(height: 12)
                HStack {
                    Label("\(positive) impact", systemImage: "circle.fill")
                        .foregroundStyle(DefectState.confirmed.color)
                    Spacer()
                    Label("\(clean) clean", systemImage: "circle.fill")
                        .foregroundStyle(DefectState.likelyRepaired.color)
                }
                .font(.caption)
                .labelStyle(LegendLabelStyle())
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Evidence")
            .accessibilityValue("\(positive) impact reports, \(clean) clean crossings")
        }
    }

    private var timesCard: some View {
        StatCard(title: "Seen") {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("First seen") {
                        Text(defect.firstSeen, format: .relative(presentation: .named))
                    }
                    LabeledContent("Last seen") {
                        Text(defect.lastSeen, format: .relative(presentation: .named))
                    }
                }
                .font(.subheadline)
            }
        }
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

// MARK: - Building blocks

/// Capsule showing a defect state in the same color as its map marker.
struct StatePill: View {
    let state: DefectState

    var body: some View {
        Label(state.displayName, systemImage: state.systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(state.color, in: Capsule())
            .contentTransition(.symbolEffect(.replace))
            .animation(.spring(duration: 0.4), value: state)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("State")
            .accessibilityValue(state.displayName)
    }
}

private struct StatCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Two segments proportional to O (positive) and C (clean) evidence counts.
private struct EvidenceSplitBar: View {
    let positive: Int
    let clean: Int

    var body: some View {
        GeometryReader { proxy in
            let total = positive + clean
            let positiveFraction = total > 0 ? CGFloat(positive) / CGFloat(total) : 0
            HStack(spacing: 0) {
                Rectangle()
                    .fill(DefectState.confirmed.color)
                    .frame(width: proxy.size.width * positiveFraction)
                Rectangle()
                    .fill(total > 0 ? DefectState.likelyRepaired.color : Color.secondary.opacity(0.3))
            }
            .clipShape(Capsule())
            .animation(.easeInOut, value: positiveFraction)
        }
    }
}

private struct LegendLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title.foregroundStyle(.primary)
        }
    }
}
