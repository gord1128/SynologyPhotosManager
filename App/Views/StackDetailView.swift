import SwiftUI
import FotoKit

/// The members of a similar-photo stack, opened by clicking a stack in the
/// collapsed timeline (like Synology Photos). Reuses the standard detail grid so
/// selection, preview, download, favorite, delete all work inside the stack.
struct StackDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let rep: FotoItem
    let service: FotoService
    let loader: ThumbnailLoader

    @State private var grid: ItemGridViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let grid {
                    DetailGridView(grid: grid, emptyMessage: "묶음이 비어 있습니다")
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("비슷한 사진 \(rep.stackCount)장")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .task(id: rep.id) {
            let ids = orderedMemberIDs
            grid = ItemGridViewModel(loader: loader) { offset, _ in
                // All members resolve in one page (a stack is small); the roster
                // is fetched via Browse.Item get — the id param on SimilarItem.list
                // is ignored on this DSM, so we expand by the roster instead.
                guard offset == 0 else { return [] }
                let items = try await service.items(ids: ids)
                let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
                return ids.compactMap { byId[$0] }   // preserve top-pick-first order
            }
        }
    }

    /// Roster with the server's top pick first, so the "keeper" leads.
    private var orderedMemberIDs: [Int] {
        guard let similar = rep.similar else { return [rep.id] }
        let top = similar.topPick
        return [top] + similar.itemId.filter { $0 != top }
    }
}
