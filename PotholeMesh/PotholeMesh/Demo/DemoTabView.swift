//
//  DemoTabView.swift
//  PotholeMesh
//
//  Demo tab: status card for the demo defect, simulator controls, event log,
//  and the server URL / health row (Requirement 13).
//

import SwiftUI

struct DemoTabView: View {
    @Environment(DemoSimulator.self) private var simulator
    @Environment(\.apiClient) private var api

    @State private var banner: DefectState?
    @State private var transitionCount = 0
    @State private var serverURLText = AppConfig.baseURLString()
    @State private var health: HealthStatus = .unknown
    @FocusState private var urlFieldFocused: Bool

    var body: some View {
        @Bindable var simulator = simulator

        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    DemoStatusCard(
                        defect: simulator.demoDefect,
                        hasPothole: simulator.hasPothole,
                        isRepaired: simulator.isRepaired,
                        transitionCount: transitionCount
                    )

                    if simulator.isStalled {
                        stalledCard
                    }

                    controlsCard(rate: $simulator.rate, speed: $simulator.speed)
                    logCard
                    serverCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Demo")
            .scrollDismissesKeyboard(.interactively)
        }
        .overlay(alignment: .top) {
            if let banner {
                TransitionBanner(state: banner)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.4), value: banner)
        .animation(.easeInOut(duration: 0.25), value: simulator.isStalled)
        .sensoryFeedback(.success, trigger: transitionCount)
        .onChange(of: simulator.demoDefect?.state) { oldState, newState in
            guard let newState, newState != oldState else { return }
            banner = newState
            transitionCount += 1
        }
        .task(id: transitionCount) {
            guard transitionCount > 0 else { return }
            try? await Task.sleep(for: .seconds(2.5))
            banner = nil
        }
        .task {
            await checkHealth()
            if !simulator.isRunning {
                await simulator.refreshDemoDefect()
            }
        }
    }

    // MARK: Sections

    private var stalledCard: some View {
        DemoCard {
            HStack(spacing: 12) {
                Image(systemName: "wifi.slash")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Server unreachable")
                        .font(.headline)
                    Text("Traffic paused after repeated failures. Check the server URL, then resume.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Resume") { simulator.startTraffic() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Restarts virtual traffic")
            }
        }
    }

    private func controlsCard(rate: Binding<TrafficRate>, speed: Binding<SimulationSpeed>) -> some View {
        DemoCard(title: "Simulation") {
            VStack(spacing: 12) {
                Button {
                    simulator.toggleTraffic()
                } label: {
                    Label(simulator.isRunning ? "PAUSE TRAFFIC" : "START TRAFFIC",
                          systemImage: simulator.isRunning ? "pause.fill" : "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(simulator.isRunning ? .orange : .blue)
                .disabled(simulator.isResetting)

                HStack(spacing: 12) {
                    Button {
                        simulator.injectPothole()
                    } label: {
                        Label("INJECT POTHOLE", systemImage: "exclamationmark.triangle")
                            .frame(maxWidth: .infinity)
                    }
                    .tint(DefectState.confirmed.color)

                    Button {
                        simulator.repairPothole()
                    } label: {
                        Label("REPAIR POTHOLE", systemImage: "wrench.and.screwdriver")
                            .frame(maxWidth: .infinity)
                    }
                    .tint(DefectState.likelyRepaired.color)
                }
                .buttonStyle(.bordered)
                .font(.subheadline.weight(.semibold))
                .disabled(simulator.isResetting)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Traffic rate")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Picker("Traffic rate", selection: rate) {
                        ForEach(TrafficRate.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Simulation speed")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Picker("Simulation speed", selection: speed) {
                        ForEach(SimulationSpeed.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                HStack {
                    Text("One trip every \(simulator.tripInterval, format: .number.precision(.fractionLength(0...2))) s")
                    Spacer()
                    Text("Next: \(DemoTrip.vehicleLabel(simulator.nextTripNumber))")
                        .monospacedDigit()
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                Button(role: .destructive) {
                    Task { await simulator.resetDemo() }
                } label: {
                    Label("RESET DEMO", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .font(.subheadline.weight(.semibold))
                .disabled(simulator.isResetting)
                .accessibilityHint("Pauses traffic and deletes all defects and evidence on the server")
            }
        }
    }

    private var logCard: some View {
        DemoCard(title: "Event log") {
            if simulator.log.isEmpty {
                Text("No events yet. Inject a pothole and start traffic.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(simulator.log.newestFirst) { entry in
                        LogRow(entry: entry)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.2), value: simulator.log.entries.last?.id)
            }
        }
    }

    private var serverCard: some View {
        DemoCard(title: "Server") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("http://192.168.1.20:8000", text: $serverURLText)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($urlFieldFocused)
                        .onSubmit(saveServerURL)
                        .accessibilityLabel("Server URL")
                    Button("Save", action: saveServerURL)
                        .buttonStyle(.bordered)
                }
                if AppConfig.makeURL(from: AppConfig.normalize(serverURLText)) == nil, !serverURLText.isEmpty {
                    Text("Enter a URL like http://<Mac IP>:8000")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack {
                    Label(health.label, systemImage: health.systemImage)
                        .foregroundStyle(health.color)
                        .font(.subheadline)
                        .accessibilityLabel("Server health")
                        .accessibilityValue(health.label)
                    Spacer()
                    Button("Check") { Task { await checkHealth() } }
                        .disabled(health == .checking)
                }
            }
        }
    }

    // MARK: Actions

    private func saveServerURL() {
        AppConfig.setBaseURLOverride(serverURLText)
        serverURLText = AppConfig.baseURLString()
        urlFieldFocused = false
        Task { await checkHealth() }
    }

    private func checkHealth() async {
        guard let api else {
            health = .failed("No API client")
            return
        }
        health = .checking
        do {
            try await api.health()
            health = .ok
        } catch {
            health = .failed(DemoSimulator.describe(error).capitalizedFirst)
        }
    }
}

// MARK: - Health

private enum HealthStatus: Equatable {
    case unknown, checking, ok
    case failed(String)

    var label: String {
        switch self {
        case .unknown: "Not checked"
        case .checking: "Checking…"
        case .ok: "Server healthy"
        case .failed(let reason): reason
        }
    }

    var systemImage: String {
        switch self {
        case .unknown: "questionmark.circle"
        case .checking: "arrow.triangle.2.circlepath"
        case .ok: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .unknown, .checking: .secondary
        case .ok: .green
        case .failed: .red
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Status card

private struct DemoStatusCard: View {
    let defect: RoadDefect?
    let hasPothole: Bool
    let isRepaired: Bool
    let transitionCount: Int

    var body: some View {
        DemoCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Demo defect")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(defect.map { "Defect #\($0.id)" } ?? "None yet")
                            .font(.title2.bold())
                    }
                    Spacer()
                    if let defect {
                        StatePill(state: defect.state)
                            .keyframeAnimator(initialValue: 1.0, trigger: transitionCount) { content, scale in
                                content.scaleEffect(scale)
                            } keyframes: { _ in
                                SpringKeyframe(1.2, duration: 0.15)
                                SpringKeyframe(1.0, duration: 0.35)
                            }
                    }
                }

                if let defect {
                    HStack(spacing: 0) {
                        metric("Confidence", DefectDetailSheet.percent(defect.confidence))
                        metric("Impact devices", "\(defect.positiveUniqueDeviceCount)")
                        metric("Clean devices", "\(defect.cleanUniqueDeviceCount)")
                        metric("Severity", "\(Int(defect.severity.rounded()))")
                    }
                } else {
                    Text("Inject a pothole and start traffic to create one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Image(systemName: groundTruthIcon)
                        .accessibilityHidden(true)
                    Text("Ground truth: \(groundTruthText)")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: defect)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.bold().monospacedDigit())
                .contentTransition(.numericText())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    private var groundTruthText: String {
        if isRepaired { return "pothole repaired" }
        return hasPothole ? "pothole present" : "no pothole"
    }

    private var groundTruthIcon: String {
        if isRepaired { return "wrench.and.screwdriver" }
        return hasPothole ? "exclamationmark.triangle" : "road.lanes"
    }
}

// MARK: - Building blocks

private struct TransitionBanner: View {
    let state: DefectState

    var body: some View {
        Label("Defect \(state.displayName.lowercased())", systemImage: state.systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(state.color, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            .accessibilityLabel("Demo defect is now \(state.displayName)")
    }
}

private struct LogRow: View {
    let entry: DemoLogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(entry.text)
                .font(.footnote.weight(isMilestone ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.date, format: .dateTime.hour().minute().second())
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var isMilestone: Bool {
        switch entry.kind {
        case .created, .transition: true
        default: false
        }
    }

    private var icon: String {
        switch entry.kind {
        case .impact: "waveform.path.ecg"
        case .cleanCrossing: "car.side"
        case .created: DefectState.suspected.systemImage
        case .transition(let state): state.systemImage
        case .warning: "exclamationmark.circle"
        case .info: "info.circle"
        }
    }

    private var color: Color {
        switch entry.kind {
        case .impact: DefectState.confirmed.color
        case .cleanCrossing: DefectState.likelyRepaired.color
        case .created: DefectState.suspected.color
        case .transition(let state): state.color
        case .warning: .orange
        case .info: .secondary
        }
    }
}

private struct DemoCard<Content: View>: View {
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
    DemoTabView()
        .environment(DemoSimulator(api: api))
        .environment(\.apiClient, api)
}
