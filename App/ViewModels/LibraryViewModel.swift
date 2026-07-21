import Foundation
import Observation
import FotoKit

/// Drives the photo grid: paginated item loading + date-sectioned grouping +
/// selection. One instance per connected `FotoService` (recreated on
/// connection/space change).
@Observable
@MainActor
final class LibraryViewModel {
    // MARK: - Filters (Synology-style: shown from the timeline's 필터 button)

    enum TypeFilter: String, CaseIterable, Identifiable {
        case all = "전체", photo = "사진", video = "동영상"
        var id: String { rawValue }
        var itemTypes: [Int] { self == .all ? [0, 1] : (self == .photo ? [0] : [1]) }
    }
    enum PersonPolicy: String, CaseIterable, Identifiable {
        case or = "아무나", and = "모두"
        var id: String { rawValue }
        var apiValue: String { self == .or ? "or" : "and" }
    }

    var typeFilter: TypeFilter = .all
    var favoriteOnly = false
    var dateFilterActive = false
    var startDate = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    var endDate = Date()
    var selectedPersonIds: Set<Int> = []
    var personPolicy: PersonPolicy = .or
    /// Place filter — COUNTRIES only (top-level geocoding nodes).
    var selectedCountryIds: Set<Int> = []
    var selectedCameraIds: Set<Int> = []
    var selectedLensIds: Set<Int> = []
    var selectedIsoIds: Set<Int> = []
    var selectedApertureIds: Set<Int> = []

    private(set) var facets = FotoFilterFacets()
    private(set) var namedPeople: [FotoPerson] = []
    /// Top-level countries for the place filter.
    var countries: [FotoPlace] { facets.geocoding }

    var hasActiveFilter: Bool {
        typeFilter != .all || favoriteOnly || dateFilterActive || !selectedPersonIds.isEmpty
            || !selectedCountryIds.isEmpty || !selectedCameraIds.isEmpty
            || !selectedLensIds.isEmpty || !selectedIsoIds.isEmpty || !selectedApertureIds.isEmpty
    }
    var activeFilterCount: Int {
        var n = 0
        if typeFilter != .all { n += 1 }
        if favoriteOnly { n += 1 }
        if dateFilterActive { n += 1 }
        for s in [selectedPersonIds, selectedCountryIds, selectedCameraIds, selectedLensIds, selectedIsoIds, selectedApertureIds] where !s.isEmpty { n += 1 }
        return n
    }

    private var timeRanges: [(start: Int, end: Int)] {
        guard dateFilterActive else { return [] }
        let cal = Calendar.current
        let start = cal.startOfDay(for: min(startDate, endDate))
        let endDay = cal.startOfDay(for: max(startDate, endDate))
        let end = cal.date(byAdding: DateComponents(day: 1, second: -1), to: endDay) ?? endDay
        return [(Int(start.timeIntervalSince1970), Int(end.timeIntervalSince1970))]
    }

    /// Loads named people + facet values for the filter panel (once each).
    func loadFiltersIfNeeded() async {
        if namedPeople.isEmpty {
            namedPeople = ((try? await service.persons()) ?? []).filter(\.isNamed)
        }
        if facets.geocoding.isEmpty && facets.camera.isEmpty {
            facets = (try? await service.filterFacets()) ?? FotoFilterFacets()
        }
    }

    /// Re-runs the timeline with the current filters (called when a filter changes).
    func applyFilters() async {
        items = []
        sections = []
        reachedEnd = false
        errorMessage = nil
        clearSelection()
        await loadMore()
    }

    func clearAllFilters() {
        resetFilterSelections()
        Task { await applyFilters() }
    }

    // MARK: - Smart albums (saved filters)

    /// Snapshots the current filter selection as a persistable criteria (T2).
    var currentCriteria: SmartAlbumCriteria {
        SmartAlbumCriteria(
            typeFilterRaw: typeFilter.rawValue,
            favoriteOnly: favoriteOnly,
            dateFilterActive: dateFilterActive,
            startDate: startDate, endDate: endDate,
            personIds: selectedPersonIds.sorted(),
            personPolicyRaw: personPolicy.rawValue,
            countryIds: selectedCountryIds.sorted(),
            cameraIds: selectedCameraIds.sorted(),
            lensIds: selectedLensIds.sorted(),
            isoIds: selectedIsoIds.sorted(),
            apertureIds: selectedApertureIds.sorted())
    }

    /// Restores a saved filter and re-runs the timeline (used when a smart album
    /// is opened from the sidebar).
    func apply(_ c: SmartAlbumCriteria) {
        typeFilter = TypeFilter(rawValue: c.typeFilterRaw) ?? .all
        favoriteOnly = c.favoriteOnly
        dateFilterActive = c.dateFilterActive
        startDate = c.startDate
        endDate = c.endDate
        selectedPersonIds = Set(c.personIds)
        personPolicy = PersonPolicy(rawValue: c.personPolicyRaw) ?? .or
        selectedCountryIds = Set(c.countryIds)
        selectedCameraIds = Set(c.cameraIds)
        selectedLensIds = Set(c.lensIds)
        selectedIsoIds = Set(c.isoIds)
        selectedApertureIds = Set(c.apertureIds)
        Task { await applyFilters() }
    }

    /// Clears every filter selection WITHOUT reloading. Used on a personal↔shared
    /// space switch: the id-based facets (people, places, camera/lens/…) are
    /// space-specific — `person_id` especially is unique per space — so carrying a
    /// previous space's selections over would filter the new space by invalid ids
    /// (wrong / empty results). The caller reloads afterwards.
    func resetFilterSelections() {
        typeFilter = .all
        favoriteOnly = false
        dateFilterActive = false
        selectedPersonIds = []; selectedCountryIds = []
        selectedCameraIds = []; selectedLensIds = []; selectedIsoIds = []; selectedApertureIds = []
    }

    // MARK: -

    let service: FotoService
    let thumbnailLoader: ThumbnailLoader

    private(set) var items: [FotoItem] = []
    /// Grouped view of `items` at the current `scale`, rebuilt on append.
    private(set) var sections: [TimelineSection] = []
    /// Grouping granularity (연도/월/일). Changing it regroups loaded items.
    private(set) var scale: TimelineScale = .month
    private(set) var totalCount = 0
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    /// Multi-selection (item ids). `primaryID` anchors shift-range + keyboard nav.
    var selectedIDs: Set<Int> = []
    private(set) var primaryID: Int?

    /// The single selected item (nil when 0 or many selected).
    var selectedItem: FotoItem? {
        guard selectedIDs.count == 1, let id = selectedIDs.first else { return nil }
        return items.first { $0.id == id }
    }
    var selectedItems: [FotoItem] { items.filter { selectedIDs.contains($0.id) } }

    private var reachedEnd = false
    // Larger pages + earlier prefetch = fewer sequential round-trips when the
    // user drags the scrollbar far, so the grid keeps up.
    private let pageSize = 400

    init(service: FotoService) {
        self.service = service
        self.thumbnailLoader = ThumbnailLoader(service: service)
        // Honor the user's default timeline granularity (설정 창).
        if let raw = UserDefaults.standard.string(forKey: "defaultScale"),
           let saved = TimelineScale(rawValue: raw) {
            self.scale = saved
        }
    }

    func loadInitial() async {
        guard items.isEmpty else { return }
        if let count = try? await service.itemCount() { totalCount = count }
        await loadMore()
    }

    /// Switches grouping granularity and regroups the loaded items.
    func setScale(_ newScale: TimelineScale) {
        guard newScale != scale else { return }
        scale = newScale
        sections = TimelineGrouping.sections(from: items, scale: scale)
    }

    func loadMore() async {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        errorMessage = nil   // clear any stale failure so a retry starts clean
        defer { isLoading = false }
        do {
            let next: [FotoItem]
            if hasActiveFilter {
                next = try await service.filteredItems(
                    itemTypes: typeFilter.itemTypes, timeRanges: timeRanges,
                    personIds: Array(selectedPersonIds), personPolicy: personPolicy.apiValue,
                    geocodingIds: Array(selectedCountryIds), favoriteOnly: favoriteOnly,
                    cameraIds: Array(selectedCameraIds), lensIds: Array(selectedLensIds),
                    isoIds: Array(selectedIsoIds), apertureIds: Array(selectedApertureIds),
                    offset: items.count, limit: pageSize)
            } else {
                // Collapsed timeline (like Synology Photos): similar/burst shots
                // fold into one stack row (its representative carries `.similar`).
                next = try await service.similarPage(offset: items.count, limit: pageSize)
            }
            if next.isEmpty {
                reachedEnd = true
            } else {
                items.append(contentsOf: next)
                sections = TimelineGrouping.sections(from: items, scale: scale)
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Year jump (right-edge scrubber)

    /// The year a section belongs to, decoded from its scale-dependent id.
    private func year(of section: TimelineSection) -> Int {
        switch scale {
        case .year: return section.id
        case .month: return section.id / 100
        case .day: return section.id / 10_000
        }
    }

    /// Distinct years currently loaded, newest first (sections are newest-first).
    var loadedYears: [Int] {
        var seen = Set<Int>()
        var out: [Int] = []
        for section in sections {
            let y = year(of: section)
            if seen.insert(y).inserted { out.append(y) }
        }
        return out
    }

    /// The id of the first (newest) loaded section in a given year — the jump
    /// target for `ScrollViewReader`.
    func firstSectionID(forYear year: Int) -> Int? {
        sections.first { self.year(of: $0) == year }?.id
    }

    /// Loads more pages until the given year appears (or the timeline ends), so a
    /// year further back than what's loaded can still be jumped to. Bounded by
    /// the library size (~thousands of photos → a handful of pages).
    func ensureYearLoaded(_ year: Int) async {
        while firstSectionID(forYear: year) == nil && !reachedEnd {
            await loadMore()
        }
    }

    /// True when `item` is within the last 150 loaded items — prefetch early so
    /// content is ready before the user reaches it. O(150), not O(n).
    func shouldLoadMore(after item: FotoItem) -> Bool {
        items.suffix(150).contains { $0.id == item.id }
    }

    /// Applies a deletion locally (no reload → scroll position preserved).
    func removeItems(ids: Set<Int>) {
        guard !ids.isEmpty else { return }
        let before = items.count
        items.removeAll { ids.contains($0.id) }
        guard items.count != before else { return }
        sections = TimelineGrouping.sections(from: items, scale: scale)
        totalCount = max(0, totalCount - (before - items.count))
        selectedIDs.subtract(ids)
        if let p = primaryID, ids.contains(p) { primaryID = nil }
    }

    // MARK: - Selection (click + keyboard)

    func selectSingle(_ id: Int) { selectedIDs = [id]; primaryID = id }

    func toggle(_ id: Int) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
        primaryID = id
    }

    func selectRange(to id: Int) {
        guard let anchor = primaryID,
              let a = items.firstIndex(where: { $0.id == anchor }),
              let b = items.firstIndex(where: { $0.id == id }) else { selectSingle(id); return }
        let range = a <= b ? a...b : b...a
        selectedIDs.formUnion(items[range].map(\.id))
    }

    func clearSelection() { selectedIDs = []; primaryID = nil }

    func selectAll() {
        selectedIDs = Set(items.map(\.id))
        primaryID = items.last?.id
    }

    private var primaryIndex: Int? {
        guard let id = primaryID else { return nil }
        return items.firstIndex { $0.id == id }
    }

    func selectPrevious() {
        guard let idx = primaryIndex else { selectSingle(items.first?.id ?? -1); return }
        if idx > 0 { selectSingle(items[idx - 1].id) }
    }

    func selectNext() {
        guard let idx = primaryIndex else { selectSingle(items.first?.id ?? -1); return }
        if idx < items.count - 1 { selectSingle(items[idx + 1].id) }
        if idx >= items.count - 100 { Task { await loadMore() } }
    }

    func reload() async {
        items = []
        sections = []
        reachedEnd = false
        errorMessage = nil
        clearSelection()
        // Facets/people are space-specific — drop so the panel refetches.
        facets = FotoFilterFacets()
        namedPeople = []
        await loadInitial()
    }
}
