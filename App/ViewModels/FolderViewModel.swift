import Foundation
import Observation
import FotoKit

/// Drives the folder browser: a breadcrumb path, the current folder's
/// subfolders, and its (paginated) items. Shares the thumbnail loader style of
/// LibraryViewModel.
@Observable
@MainActor
final class FolderViewModel {
    let service: FotoService
    let thumbnailLoader: ThumbnailLoader

    /// Breadcrumb from root (empty == root, whose parent id is 0).
    private(set) var path: [FotoFolder] = []
    private(set) var subfolders: [FotoFolder] = []
    private(set) var items: [FotoItem] = []
    private(set) var isLoading = false

    var selectedIDs: Set<Int> = []
    private(set) var primaryID: Int?
    var selectedItem: FotoItem? {
        guard selectedIDs.count == 1, let id = selectedIDs.first else { return nil }
        return items.first { $0.id == id }
    }
    var selectedItems: [FotoItem] { items.filter { selectedIDs.contains($0.id) } }

    var currentId: Int { path.last?.id ?? 0 }

    private var reachedEnd = false
    private let pageSize = 400
    private var loadedOnce = false

    init(service: FotoService) {
        self.service = service
        self.thumbnailLoader = ThumbnailLoader(service: service)
    }

    func loadIfNeeded() async {
        guard !loadedOnce else { return }
        loadedOnce = true
        await reload()
    }

    func reload() async {
        items = []
        subfolders = []
        reachedEnd = false
        clearSelection()
        subfolders = (try? await service.folders(parentId: currentId)) ?? []
        await loadMore()
    }

    /// Applies a deletion locally (no reload → scroll position preserved).
    func removeItems(ids: Set<Int>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        selectedIDs.subtract(ids)
        if let p = primaryID, ids.contains(p) { primaryID = nil }
    }

    func selectSingle(_ id: Int) { selectedIDs = [id]; primaryID = id }
    func toggle(_ id: Int) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
        primaryID = id
    }
    func selectRange(to id: Int) {
        guard let anchor = primaryID,
              let a = items.firstIndex(where: { $0.id == anchor }),
              let b = items.firstIndex(where: { $0.id == id }) else { selectSingle(id); return }
        selectedIDs.formUnion(items[(a <= b ? a...b : b...a)].map(\.id))
    }
    func clearSelection() { selectedIDs = []; primaryID = nil }
    func selectAll() { selectedIDs = Set(items.map(\.id)); primaryID = items.last?.id }

    func loadMore() async {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }
        if let next = try? await service.items(inFolder: currentId, offset: items.count, limit: pageSize) {
            if next.isEmpty { reachedEnd = true } else { items.append(contentsOf: next) }
        } else {
            reachedEnd = true
        }
    }

    func open(_ folder: FotoFolder) async {
        path.append(folder)
        await reload()
    }

    /// Jump to breadcrumb index (`nil` = root).
    func navigate(to index: Int?) async {
        if let index { path = Array(path.prefix(index + 1)) } else { path = [] }
        await reload()
    }

    func shouldLoadMore(after item: FotoItem) -> Bool {
        items.suffix(150).contains { $0.id == item.id }
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
        if idx >= items.count - 5 { Task { await loadMore() } }
    }
}
