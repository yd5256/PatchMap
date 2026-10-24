//
//  ContentView.swift
//  PotholeMesh
//
//  Created by Yavuz Damkaci on 10/24/26.
//

import SwiftUI

/// Root view: exactly three tabs, in the order Map, Drive, Demo (Requirement 10.1).
struct ContentView: View {
    var body: some View {
        TabView {
            Tab("Map", systemImage: "map") {
                MapTabView()
            }
            Tab("Drive", systemImage: "car") {
                DriveTabView()
            }
            Tab("Demo", systemImage: "play.circle") {
                DemoTabView()
            }
        }
    }
}

#Preview {
    let api = URLSessionAPIClient()
    let store = DefectStore(api: api)
    let uploader = EvidenceUploader(api: api)
    ContentView()
        .environment(store)
        .environment(DemoSimulator(api: api))
        .environment(uploader)
        .environment(DriveSession(uploader: uploader, defectStore: store, deviceId: "preview"))
        .environment(\.apiClient, api)
}
