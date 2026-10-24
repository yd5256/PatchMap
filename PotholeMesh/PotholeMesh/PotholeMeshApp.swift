//
//  PotholeMeshApp.swift
//  PotholeMesh
//
//  Created by Yavuz Damkaci on 10/24/26.
//

import SwiftUI

@main
struct PotholeMeshApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @State private var defectStore: DefectStore
    @State private var demoSimulator: DemoSimulator
    @State private var evidenceUploader: EvidenceUploader
    @State private var driveSession: DriveSession
    private let apiClient: URLSessionAPIClient
    private let deviceId: String

    init() {
        let api = URLSessionAPIClient()
        apiClient = api
        let deviceId = DeviceIdentity.deviceId()
        self.deviceId = deviceId
        let store = DefectStore(api: api)
        let uploader = EvidenceUploader(api: api)
        _defectStore = State(initialValue: store)
        _demoSimulator = State(initialValue: DemoSimulator(api: api))
        _evidenceUploader = State(initialValue: uploader)
        _driveSession = State(initialValue: DriveSession(uploader: uploader, defectStore: store, deviceId: deviceId))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(defectStore)
                .environment(demoSimulator)
                .environment(evidenceUploader)
                .environment(driveSession)
                .environment(\.apiClient, apiClient)
                .environment(\.deviceId, deviceId)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                defectStore.startPolling()
            } else {
                defectStore.stopPolling()
            }
            // No background sensing: end the session when the app leaves the foreground.
            if phase == .background {
                driveSession.stop()
            }
        }
    }
}

extension EnvironmentValues {
    /// Shared API client used by every tab.
    @Entry var apiClient: APIClientProtocol? = nil
    /// The per-install anonymous device id.
    @Entry var deviceId: String = ""
}
