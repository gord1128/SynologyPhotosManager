import Foundation
import Observation
import CoreLocation
import SynoKit
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
    /// How many photos the sweep has walked (not how many had coordinates) —
    /// drives the "N장 훑음" progress line while the map fills in.
    private(set) var scanned = 0
    /// True when the budget ran out before the library did, so the view can
    /// offer 「더 불러오기」 instead of silently showing a partial map.
    private(set) var hasMore = false
    var errorMessage: String?

    private let pageSize = 500   // matches the spike's verified page size
    /// Cap on pages per sweep: 40 × 500 = 20,000 photos.
    ///
    /// The spike this screen was designed against measured 2,813 items (<1 s).
    /// The cost is linear, so a 100k-photo library means ~200 sequential
    /// round-trips and 100k decoded items held in memory before a single pin
    /// appears. Newest-first, 20k covers years of photos for most people; the
    /// rest is one button away.
    private let pageBudget = 40
    /// Where the next sweep resumes from (`loadMore`).
    private var nextOffset = 0

    init(service: FotoService) {
        self.service = service
        self.thumbnailLoader = ThumbnailLoader(service: service)
    }

    func loadIfNeeded() async {
        guard !didLoad else { return }
        await reload()
    }

    func reload() async {
        geoItems = []
        scanned = 0
        nextOffset = 0
        hasMore = false
        didLoad = false
        await sweep()
    }

    /// Continues the sweep past the budget, at the user's request.
    func loadMore() async {
        guard hasMore, !isLoading else { return }
        await sweep()
    }

    private func sweep() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false; didLoad = true }
        do {
            var pages = 0
            while pages < pageBudget {
                // The map tab can be left while a page is in flight; without
                // this the sweep runs to completion against a view nobody is
                // looking at.
                if Task.isCancelled { return }
                // Only the thumbnail descriptor + gps — small (~230 B/item).
                let page = try await service.items(offset: nextOffset, limit: pageSize, additional: ["thumbnail", "gps"])
                if page.isEmpty { hasMore = false; return }
                for it in page {
                    if let g = it.additional?.gps, !(g.latitude == 0 && g.longitude == 0) {
                        geoItems.append(GeoItem(item: it, latitude: g.latitude, longitude: g.longitude))
                    }
                }
                // Publish as we go: pins appear while the sweep continues,
                // instead of an empty map for the whole scan.
                nextOffset += page.count
                scanned = nextOffset
                pages += 1
                if page.count < pageSize { hasMore = false; return }
            }
            hasMore = true
            SynoLog.app.info("지도 스윕이 상한에 걸림 scanned=\(self.scanned, privacy: .public) pins=\(self.geoItems.count, privacy: .public)")
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Keep what was already collected: a partial map with an error line
            // is more use than a blank one, and `hasMore` lets them retry.
            hasMore = true
        }
    }
}
