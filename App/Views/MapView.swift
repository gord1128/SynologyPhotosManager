import SwiftUI
import MapKit
import FotoKit

/// "지도(Map)" — every geolocated photo on a map, clustered client-side (Apple
/// Photos "장소"). Loads all coordinates once (cheap — see MapViewModel), buckets
/// them into a grid sized to the visible span so clusters merge/split with zoom,
/// and opens a cluster's photos in a sheet (filtered from memory, no new query).
struct MapView: View {
    @Bindable var vm: MapViewModel

    @State private var position: MapCameraPosition = .automatic
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var selection: ClusterSelection?

    var body: some View {
        ZStack {
            Map(position: $position) {
                ForEach(displayClusters) { cluster in
                    Annotation("", coordinate: cluster.coordinate) {
                        clusterBadge(cluster)
                    }
                }
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                visibleRegion = context.region
            }

            if vm.geoItems.isEmpty {
                overlayState
            }
        }
        .navigationTitle("지도")
        .task {
            await vm.loadIfNeeded()
            if !vm.geoItems.isEmpty { position = .region(boundingRegion) }
        }
        .sheet(item: $selection) { sel in
            MapClusterGrid(items: sel.items, loader: vm.thumbnailLoader)
        }
    }

    @ViewBuilder
    private var overlayState: some View {
        if vm.isLoading {
            ProgressView("위치 정보를 불러오는 중…")
                .padding(DS.s4).dsCard()
        } else if let message = vm.errorMessage {
            ContentUnavailableView("불러오기 실패", systemImage: "exclamationmark.triangle", description: Text(message))
        } else {
            ContentUnavailableView("위치 정보가 있는 사진이 없습니다",
                                   systemImage: "mappin.slash",
                                   description: Text("GPS가 기록된 사진이 지도에 표시됩니다."))
        }
    }

    // MARK: - Cluster badge

    private func clusterBadge(_ cluster: MapCluster) -> some View {
        Button {
            selection = ClusterSelection(items: cluster.items)
        } label: {
            Text(cluster.count > 999 ? "999+" : "\(cluster.count)")
                .font(.caption.weight(.bold)).monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, cluster.count > 1 ? 8 : 0)
                .frame(minWidth: 34, minHeight: 34)
                .background(Circle().fill(Color.accentColor).shadow(radius: 2))
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Clustering (grid buckets sized to the visible span)

    private var displayClusters: [MapCluster] {
        clusters(in: visibleRegion ?? boundingRegion)
    }

    private func clusters(in region: MKCoordinateRegion) -> [MapCluster] {
        let items = vm.geoItems
        guard !items.isEmpty else { return [] }
        // ~10×10 buckets across the viewport → merge when zoomed out, split in.
        let latStep = max(region.span.latitudeDelta / 10, 0.00005)
        let lonStep = max(region.span.longitudeDelta / 10, 0.00005)

        var buckets: [String: [MapViewModel.GeoItem]] = [:]
        for g in items {
            let row = Int((g.latitude / latStep).rounded(.down))
            let col = Int((g.longitude / lonStep).rounded(.down))
            buckets["\(row)_\(col)", default: []].append(g)
        }
        return buckets.map { key, group in
            let lat = group.reduce(0) { $0 + $1.latitude } / Double(group.count)
            let lon = group.reduce(0) { $0 + $1.longitude } / Double(group.count)
            return MapCluster(id: key,
                              coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                              items: group.map(\.item))
        }
    }

    /// Region enclosing all coordinates (initial camera + clustering fallback).
    private var boundingRegion: MKCoordinateRegion {
        let items = vm.geoItems
        guard let first = items.first else {
            return MKCoordinateRegion(center: .init(latitude: 36.5, longitude: 127.8),
                                      span: .init(latitudeDelta: 4, longitudeDelta: 4))
        }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for g in items {
            minLat = min(minLat, g.latitude); maxLat = max(maxLat, g.latitude)
            minLon = min(minLon, g.longitude); maxLon = max(maxLon, g.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.3, 0.02),
                                    longitudeDelta: max((maxLon - minLon) * 1.3, 0.02))
        return MKCoordinateRegion(center: center, span: span)
    }
}

/// One map cluster: a representative coordinate + the photos it holds.
private struct MapCluster: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let items: [FotoItem]
    var count: Int { items.count }
}

/// Sheet payload — a tapped cluster's photos (Identifiable for `.sheet(item:)`).
private struct ClusterSelection: Identifiable {
    let id = UUID()
    let items: [FotoItem]
}

/// The photos at one map location, in the standard detail grid (select, preview,
/// download, favorite, delete). Items are already in memory, so the grid's
/// page-fetcher just returns them (mirrors StackDetailView).
private struct MapClusterGrid: View {
    @Environment(\.dismiss) private var dismiss
    let items: [FotoItem]
    let loader: ThumbnailLoader

    @State private var grid: ItemGridViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let grid {
                    DetailGridView(grid: grid, emptyMessage: "사진 없음")
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("이 위치의 사진 \(items.count)장")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .task {
            let fixed = items
            grid = ItemGridViewModel(loader: loader) { offset, _ in offset == 0 ? fixed : [] }
        }
    }
}
