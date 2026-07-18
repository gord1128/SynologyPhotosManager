import Foundation
import Observation
import CoreLocation
import FotoKit

/// Drives the "지도(Map)" view (T3, Apple Photos "장소" / Google Photos map).
/// The map-spike (`spike/MapSpike`, FINDINGS.md) proved the whole library pages
/// with `additional=["gps"]` in <1 s / <1 MB (2813 items, ~84% geolocated), so
/// we load EVERY coordinate up front and cluster client-side — no server-side
/// geo query. All read-only, on already-verified calls.
@Observable
@MainActor
final class MapViewModel {
    let service: FotoService
    let thumbnailLoader: ThumbnailLoader

    struct GeoItem: Identifiable {
        let item: FotoItem
        let latitude: Double
        let longitude: Double
        var id: Int { item.id }
        var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    }

    private(set) var geoItems: [GeoItem] = []
    private(set) var isLoading = false
    private(set) var didLoad = false
    var errorMessage: String?

    private let pageSize = 500   // matches the spike's verified page size

    init(service: FotoService) {
        self.service = service
        self.thumbnailLoader = ThumbnailLoader(service: service)
    }

    func loadIfNeeded() async {
        guard !didLoad else { return }
        await reload()
    }

    func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false; didLoad = true }
        do {
            var collected: [GeoItem] = []
            var offset = 0
            while true {
                // Only the thumbnail descriptor + gps — small (~230 B/item).
                let page = try await service.items(offset: offset, limit: pageSize, additional: ["thumbnail", "gps"])
                if page.isEmpty { break }
                for it in page {
                    if let g = it.additional?.gps, !(g.latitude == 0 && g.longitude == 0) {
                        collected.append(GeoItem(item: it, latitude: g.latitude, longitude: g.longitude))
                    }
                }
                offset += page.count
                if page.count < pageSize { break }
            }
            geoItems = collected
        } catch {
            geoItems = []
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
