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
    private let apiClient: URLSessionAPIClient
    private let deviceId: String

    init() {
        let api = URLSessionAPIClient()
        apiClient = api
        deviceId = DeviceIdentity.deviceId()
        _defectStore = State(initialValue: DefectStore(api: api))
        _demoSimulator = State(initialValue: DemoSimulator(api: api))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(defectStore)
                .environment(demoSimulator)
                .environment(\.apiClient, apiClient)
                .environment(\.deviceId, deviceId)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                defectStore.startPolling()
            } else {
                defectStore.stopPolling()
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
