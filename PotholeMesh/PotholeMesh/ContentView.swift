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
                PlaceholderTabView(title: "Drive", systemImage: "car",
                                   message: "On-device sensing arrives in a later build.")
            }
            Tab("Demo", systemImage: "play.circle") {
                DemoTabView()
            }
        }
    }
}

private struct PlaceholderTabView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
                .navigationTitle(title)
        }
    }
}

#Preview {
    let api = URLSessionAPIClient()
    ContentView()
        .environment(DefectStore(api: api))
        .environment(DemoSimulator(api: api))
        .environment(\.apiClient, api)
}
