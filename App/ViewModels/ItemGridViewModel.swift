import Foundation
import Observation
import FotoKit

/// Generic paginated photo-grid model for detail screens (an album's photos, a
/// person's photos): pagination via an injected page-fetcher + the standard
/// selection behaviour, mirroring LibraryViewModel.
@Observable
@MainActor
final class ItemGridViewModel {
    let thumbnailLoader: ThumbnailLoader
    private let fetchPage: (_ offset: Int, _ limit: Int) async throws -> [FotoItem]

    private(set) var items: [FotoItem] = []
    private(set) var isLoading = false
    var errorMessage: String?

    var selectedIDs: Set<Int> = []
    private(set) var primaryID: Int?

    private var reachedEnd = false
    private let pageSize = 300

    init(loader: ThumbnailLoader, fetchPage: @escaping (_ offset: Int, _ limit: Int) async throws -> [FotoItem]) {
        self.thumbnailLoader = loader
        self.fetchPage = fetchPage
    }

    var selectedItem: FotoItem? {
        guard selectedIDs.count == 1, let id = selectedIDs.first else { return nil }
        return items.first { $0.id == id }
    }
    var selectedItems: [FotoItem] { items.filter { selectedIDs.contains($0.id) } }

    func loadInitial() async {
        guard items.isEmpty, !isLoading else { return }
        await loadMore()
    }

    func loadMore() async {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let next = try await fetchPage(items.count, pageSize)
            if next.isEmpty { reachedEnd = true } else { items.append(contentsOf: next) }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func shouldLoadMore(after item: FotoItem) -> Bool {
        items.suffix(100).contains { $0.id == item.id }
    }

    func reload() async {
        items = []
        reachedEnd = false
        errorMessage = nil
        clearSelection()
        await loadMore()
    }

    /// Applies a deletion/removal locally (no reload → scroll preserved).
    func removeItems(ids: Set<Int>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        selectedIDs.subtract(ids)
        if let p = primaryID, ids.contains(p) { primaryID = nil }
    }

    // MARK: - Selection

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
        if idx >= items.count - 60 { Task { await loadMore() } }
    }
}
