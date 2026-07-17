import SwiftUI
import AppKit
import FotoKit

/// Reusable photo grid for detail screens (album / person): paginated
/// `ItemGridViewModel` + the standard selection/right-click behaviour + a local
/// Quick Look overlay (double-click, on-screen prev/next, Esc).
struct DetailGridView: View {
    @Environment(AppModel.self) private var model
    @Bindable var grid: ItemGridViewModel
    /// Screen-specific context-menu entry (앨범에서 제거 / 대표 사진 설정…).
    var extraAction: SelectablePhotoCell.ExtraAction? = nil
    var emptyMessage = "사진 없음"

    @State private var showingPreview = false

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 200), spacing: 2)]

    var body: some View {
        ZStack {
            content
            if showingPreview, let item = grid.selectedItem {
                PhotoPreviewView(
                    item: item, loader: grid.thumbnailLoader,
                    onClose: { showingPreview = false },
                    onPrev: { grid.selectPrevious() },
                    onNext: { grid.selectNext() }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showingPreview)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            guard grid.selectedItem != nil else { return .ignored }
            showingPreview.toggle()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard !grid.selectedIDs.isEmpty else { return .ignored }
            grid.selectPrevious(); return .handled
        }
        .onKeyPress(.rightArrow) {
            guard !grid.selectedIDs.isEmpty else { return .ignored }
            grid.selectNext(); return .handled
        }
        .onKeyPress(.escape) {
            if showingPreview { showingPreview = false; return .handled }
            if !grid.selectedIDs.isEmpty { grid.clearSelection(); return .handled }
            return .ignored
        }
        .task { await grid.loadInitial() }
        // Items deleted anywhere (context menu → AppModel) vanish here too.
        .onChange(of: model.deletionCounter) { grid.removeItems(ids: model.deletedIDs) }
    }

    @ViewBuilder
    private var content: some View {
        if grid.items.isEmpty && grid.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if grid.items.isEmpty {
            ContentUnavailableView(emptyMessage, systemImage: "photo.on.rectangle")
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(grid.items) { item in
                        SelectablePhotoCell(
                            item: item,
                            loader: grid.thumbnailLoader,
                            isSelected: grid.selectedIDs.contains(item.id),
                            targets: { grid.selectedIDs.contains(item.id) ? grid.selectedItems : [item] },
                            onClick: { handleClick(item) },
                            onDoubleClick: { grid.selectSingle(item.id); showingPreview = true },
                            onDeselect: { grid.clearSelection() },
                            onAppear: { if grid.shouldLoadMore(after: item) { await grid.loadMore() } },
                            extraAction: extraAction
                        )
                    }
                }
                .padding(2)
                if grid.isLoading && !grid.items.isEmpty {
                    ProgressView().controlSize(.small).padding()
                }
            }
            .onTapGesture { grid.clearSelection() }
        }
    }

    private func handleClick(_ item: FotoItem) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) { grid.toggle(item.id) }
        else if flags.contains(.shift) { grid.selectRange(to: item.id) }
        else if grid.selectedIDs == [item.id] { grid.clearSelection() }
        else { grid.selectSingle(item.id) }
    }
}
