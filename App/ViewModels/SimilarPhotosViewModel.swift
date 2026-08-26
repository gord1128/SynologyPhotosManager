import Foundation
import Observation
import SynoKit
import FotoKit

/// Drives the "유사한 항목 정리" screen: pages Synology's similar-photo groups,
/// resolves each group's members on demand, and tracks which photos the user has
/// marked to keep vs delete (default: keep the server's top pick).
@Observable
@MainActor
final class SimilarPhotosViewModel {
    let service: FotoService
    let thumbnailLoader: ThumbnailLoader

    /// One reviewable group: the metadata + its resolved member items (with
    /// thumbnails), and the set of ids the user has chosen to keep.
    @Observable
    final class Group: Identifiable {
        let meta: FotoSimilarGroup
        var members: [FotoItem] = []
        var keptIDs: Set<Int>
        var isResolved = false
        var isDismissed = false

        var id: Int { meta.id }
        init(meta: FotoSimilarGroup) {
            self.meta = meta
            self.keptIDs = [meta.topPick]     // default: keep the top pick only
        }

        var removeIDs: [Int] { members.map(\.id).filter { !keptIDs.contains($0) } }
        var removeCount: Int { max(0, (isResolved ? members.count : meta.count) - keptIDs.count) }
        func isTopPick(_ id: Int) -> Bool { id == meta.topPick }
    }

    private(set) var groups: [Group] = []
    private(set) var isLoading = false
    private(set) var didLoad = false
    /// The sweep stopped at its budget with library left over.
    private(set) var hasMore = false
    var errorMessage: String?

    /// Raw group metadata gathered so far, kept so `loadMore` can resume and
    /// re-sort without re-fetching what's already in hand.
    private var collected: [FotoSimilarGroup] = []
    private var nextOffset = 0
    private let pageSize = 500
    private let pageBudget = 40   // 20,000 photos per sweep

    init(service: FotoService) {
        self.service = service
        self.thumbnailLoader = ThumbnailLoader(service: service)
    }

    /// Total photos the user would reclaim with the current selections.
    var totalRemovable: Int {
        groups.filter { !$0.isDismissed }.reduce(0) { $0 + $1.removeCount }
    }
    var activeGroupCount: Int { groups.filter { !$0.isDismissed }.count }

    func loadIfNeeded() async {
        guard !didLoad else { return }
        await reload()
    }

    func reload() async {
        collected = []
        nextOffset = 0
        hasMore = false
        didLoad = false
        await sweep()
    }

    /// Continues past the page budget when the user asks for it.
    func loadMore() async {
        guard hasMore, !isLoading else { return }
        await sweep()
    }

    /// Walks the collapsed timeline collecting similar-photo groups.
    ///
    /// Bounded for the same reason as the map sweep: this walks the WHOLE
    /// library, and it was sized against a 2,813-item one. 20,000 photos of
    /// bursts is already more cleanup than anyone does in a sitting, and the
    /// remainder is one button away.
    private func sweep() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false; didLoad = true }
        do {
            var pages = 0
            while pages < pageBudget {
                if Task.isCancelled { return }
                let page = try await service.similarPage(offset: nextOffset, limit: pageSize)
                collected.append(contentsOf: page.compactMap(\.similar))
                nextOffset += page.count
                pages += 1
                publishGroups()
                if page.count < pageSize { hasMore = false; return }
            }
            hasMore = true
            SynoLog.app.info("유사 사진 스윕이 상한에 걸림 scanned=\(self.nextOffset, privacy: .public) groups=\(self.collected.count, privacy: .public)")
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            hasMore = true
        }
    }

    /// Rebuilds the visible list from what's been collected, largest groups
    /// first — most to gain, and the clearest bursts.
    ///
    /// Existing `Group` instances are reused by id. They carry user state the
    /// sweep must not touch: which photos are kept, which groups were dismissed,
    /// and the resolved members. Re-creating them on every page (the obvious way
    /// to write this) silently discards choices the user made while the rest of
    /// the library was still loading.
    private func publishGroups() {
        let existing = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        groups = collected
            .sorted { $0.count > $1.count }
            .map { meta in existing[meta.id] ?? Group(meta: meta) }
    }

    /// Resolves a group's member items (thumbnails) the first time it's shown.
    func resolve(_ group: Group) async {
        guard !group.isResolved else { return }
        do {
            let items = try await service.items(ids: group.meta.itemId)
            // Preserve the roster order; top pick first for a clear "keeper".
            let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            group.members = group.meta.itemId.compactMap { byId[$0] }
            group.isResolved = true
            // Drop any kept ids that no longer exist (already deleted elsewhere).
            group.keptIDs.formIntersection(Set(group.members.map(\.id)))
            if group.keptIDs.isEmpty, let first = group.members.first(where: { group.isTopPick($0.id) }) ?? group.members.first {
                group.keptIDs = [first.id]
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func toggleKeep(_ item: FotoItem, in group: Group) {
        if group.keptIDs.contains(item.id) {
            // Never allow keeping zero — that would delete the whole group.
            if group.keptIDs.count > 1 { group.keptIDs.remove(item.id) }
        } else {
            group.keptIDs.insert(item.id)
        }
    }

    /// Keep only the top pick in this group (reset to the recommended state).
    func keepTopPickOnly(_ group: Group) {
        if group.members.contains(where: { group.isTopPick($0.id) }) {
            group.keptIDs = [group.meta.topPick]
        }
    }

    /// Deletes the non-kept members of a group. Returns the deleted ids (empty if
    /// nothing to delete), or nil on failure (message set). Dismisses on success.
    func applyDeletion(_ group: Group) async -> [Int]? {
        let toDelete = group.removeIDs
        guard !toDelete.isEmpty else { group.isDismissed = true; return [] }
        do {
            try await service.deleteItems(itemIds: toDelete)
            group.isDismissed = true
            return toDelete
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// Dismiss a group without deleting anything (user chose to keep all / skip).
    func dismiss(_ group: Group) { group.isDismissed = true }
}
