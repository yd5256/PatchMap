//
//  MapTabView.swift
//  PotholeMesh
//
//  Live map of active RoadDefects (Requirement 11). Renders only what the
//  backend returned through DefectStore; never recomputes state, confidence,
//  or severity, and never requests location permission itself.
//

import CoreLocation
import MapKit
import SwiftUI

struct MapTabView: View {
    @Environment(DefectStore.self) private var store

    /// Initial camera on the Demo_Coordinate. Tab state persists, so this only
    /// applies the first time the tab appears after launch.
    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: MapTabView.demoCoordinate,
            latitudinalMeters: 400,
            longitudinalMeters: 400
        )
    )
    @State private var selectedId: Int?
    @State private var sheetDefect: RoadDefect?
    @State private var markers: [MapMarkerItem] = []
    @State private var locationAuth = LocationAuthorizationObserver()

    static let demoCoordinate = CLLocationCoordinate2D(
        latitude: AppConfig.demoLatitude,
        longitude: AppConfig.demoLongitude
    )

    var body: some View {
        Map(position: $position, selection: $selectedId) {
            if locationAuth.isAuthorized {
                UserAnnotation()
            }
            ForEach(markers) { item in
                Annotation(
                    "Defect #\(item.defect.id)",
                    coordinate: CLLocationCoordinate2D(
                        latitude: item.defect.latitude,
                        longitude: item.defect.longitude
                    ),
                    anchor: .center
                ) {
                    DefectMarker(
                        defect: item.defect,
                        isLeaving: item.isLeaving,
                        isSelected: selectedId == item.id
                    )
                    .onTapGesture { select(item) }
                    .accessibilityAction { select(item) }
                }
                .annotationTitles(.hidden)
                .tag(item.id)
            }
        }
        .mapControls {
            MapCompass()
            MapScaleView()
            if locationAuth.isAuthorized {
                MapUserLocationButton()
            }
        }
        .overlay(alignment: .top) {
            if store.connectionStatus.isUnreachable {
                ConnectionPill()
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: store.connectionStatus.isUnreachable)
        .onChange(of: store.defects, initial: true) { _, newDefects in
            reconcile(with: newDefects)
        }
        .onChange(of: selectedId) { _, newId in
            guard let newId else { return }
            if let item = markers.first(where: { $0.id == newId && !$0.isLeaving }) {
                sheetDefect = item.defect
            } else {
                selectedId = nil
            }
        }
        .sheet(item: $sheetDefect, onDismiss: { selectedId = nil }) { defect in
            DefectDetailSheet(defect: defect)
        }
    }

    private func select(_ item: MapMarkerItem) {
        guard !item.isLeaving else { return }
        selectedId = item.id
        sheetDefect = item.defect
    }

    /// Applies a successful poll: updates live markers, and fades out then
    /// removes markers whose ids the poll no longer returns (Requirement 11.6).
    private func reconcile(with defects: [RoadDefect]) {
        let result = MapMarkerReconciler.reconcile(current: markers, incoming: defects)
        markers = result.items
        for id in result.newlyLeaving {
            if selectedId == id { selectedId = nil }
            Task {
                try? await Task.sleep(for: .seconds(DefectMarker.fadeOutDuration + 0.1))
                markers = MapMarkerReconciler.removeLeaving(id: id, from: markers)
            }
        }
    }
}

/// Shown only while the backend is unreachable (Requirement 11.10).
private struct ConnectionPill: View {
    var body: some View {
        Label("Server unreachable", systemImage: "wifi.slash")
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.orange.opacity(0.6), lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            .accessibilityLabel("Server unreachable. Showing the last known defects.")
    }
}

/// Reads location authorization without ever requesting it. The Drive tab
/// owns permission requests (Requirement 11.7).
@Observable
final class LocationAuthorizationObserver: NSObject, CLLocationManagerDelegate {
    private(set) var status: CLAuthorizationStatus

    @ObservationIgnored private let manager: CLLocationManager

    override init() {
        let manager = CLLocationManager()
        self.manager = manager
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    var isAuthorized: Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let newStatus = manager.authorizationStatus
        Task { @MainActor in
            self.status = newStatus
        }
    }
}

#Preview {
    MapTabView()
        .environment(DefectStore(api: URLSessionAPIClient()))
}
