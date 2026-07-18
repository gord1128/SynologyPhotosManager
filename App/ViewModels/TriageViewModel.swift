import Foundation
import Observation
import FotoKit

/// Drives the "정리(Triage)" screen — a one-card-at-a-time keep/delete pass over
/// the timeline (Slidebox / Google Photos "free up space" style). Delete is a
/// *pending mark*, not an immediate server call: nothing is removed until the
/// user commits, matching the app's "실데이터 무손상, 확인 후 삭제" principle
/// (Synology Photos has no trash). Reuses the standard paged-items fetch.
@Observable
@MainActor
final class TriageViewModel {
    let service: FotoService
    let thumbnailLoader: ThumbnailLoader

    private(set) var items: [FotoItem] = []
    /// Index of the current card. `items[0..<index]` are the decided ones (the
    /// decided set is always exactly this prefix — see the invariant below).
    private(set) var index = 0
    private(set) var isLoading = false
    var errorMessage: String?

    /// Per-item decision (absent = undecided). Delete decisions are PENDING;
    /// `pendingDeleteItems` are only removed server-side when the caller commits.
    enum Decision { case kept, deletePending }
    private(set) var decisions: [Int: Decision] = [:]
    /// Decided item ids in order, so `undo` steps back exactly one at a time.
    private var history: [Int] = []

    private var reachedEnd = false
    private let pageSize = 200

    init(service: FotoService) {
        self.service = service
        self.thumbnailLoader = ThumbnailLoader(service: service)
    }

    // Invariant maintained by keep/markDelete/undo/applyCommitted:
    //   history == decided ids in order, and index == decisions.count, and the
    //   decided items are exactly items[0..<index]. This is what lets
    //   `applyCommitted` restore the cursor with a single `decisions.count`.

    var current: FotoItem? { items.indices.contains(index) ? items[index] : nil }
    var deletePendingCount: Int { decisions.values.filter { $0 == .deletePending }.count }
    var keptCount: Int { decisions.values.filter { $0 == .kept }.count }
    var decidedCount: Int { history.count }
    var canUndo: Bool { !history.isEmpty }
    /// No card left and the server list is exhausted → the pass is complete.
    var isAtEnd: Bool { current == nil && reachedEnd && !isLoading }
    /// Items flagged for deletion, for the commit step.
    var pendingDeleteItems: [FotoItem] { items.filter { decisions[$0.id] == .deletePending } }

    func loadInitial() async {
        guard items.isEmpty, !isLoading else { return }
        await loadMore()
    }

    private func loadMore() async {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let next = try await service.items(offset: items.count, limit: pageSize)
            if next.isEmpty { reachedEnd = true } else { items.append(contentsOf: next) }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func advance() {
        index += 1
        if index >= items.count - 20 { Task { await loadMore() } }
    }

    /// Keep the current card and move on (→).
    func keep() {
        guard let c = current else { return }
        decisions[c.id] = .kept
        history.append(c.id)
        advance()
    }

    /// Flag the current card for deletion and move on (⌫). Nothing is deleted yet.
    func markDelete() {
        guard let c = current else { return }
        decisions[c.id] = .deletePending
        history.append(c.id)
        advance()
    }

    /// Step back one decision (←).
    func undo() {
        guard let last = history.popLast() else { return }
        decisions[last] = nil
        if let i = items.firstIndex(where: { $0.id == last }) { index = i }
        else if index > 0 { index -= 1 }
    }

    /// Applies a server-side deletion (from our commit, or from another screen)
    /// locally: drops the items + their decisions and restores the cursor. Safe
    /// for any removal because the decided set stays a contiguous prefix, so the
    /// next undecided card is at `decisions.count`.
    func applyCommitted(deletedIDs: Set<Int>) {
        guard !deletedIDs.isEmpty, items.contains(where: { deletedIDs.contains($0.id) }) else { return }
        items.removeAll { deletedIDs.contains($0.id) }
        for id in deletedIDs { decisions[id] = nil }
        history.removeAll { deletedIDs.contains($0) }
        index = min(decisions.count, items.count)
    }
}
