import SwiftUI
import FotoKit

/// A photo grid cell with the standard macOS selection/right-click behaviour,
/// shared by the timeline and folder grids:
/// - single click selects; clicking the sole-selected item again deselects it
/// - ⌘-click toggles, ⇧-click extends a range (handled by the owner via `onClick`)
/// - double click opens Quick Look
/// - right-click shows a context menu (download / delete / deselect) that acts on
///   the whole selection when the clicked item is part of it, else just that item
struct SelectablePhotoCell: View {
    @Environment(AppModel.self) private var model

    /// An optional screen-specific context-menu entry (e.g. "앨범에서 제거",
    /// "대표 사진으로 설정"), applied to the selection-aware targets.
    struct ExtraAction {
        let title: String
        let systemImage: String
        /// Whether the action applies to a multi-selection (e.g. 앨범에서 제거)
        /// or only ever a single item (e.g. 대표 사진으로 설정).
        var allowsMultiple = true
        let run: ([FotoItem]) -> Void
    }

    let item: FotoItem
    let loader: ThumbnailLoader
    let isSelected: Bool
    /// Items the context-menu actions apply to (selection-aware).
    let targets: () -> [FotoItem]
    let onClick: () -> Void
    let onDoubleClick: () -> Void
    let onDeselect: () -> Void
    /// Pagination hook, run when the cell appears.
    let onAppear: () async -> Void
    var extraAction: ExtraAction? = nil
    /// Passed to ThumbnailCell — true for the justified timeline (fills the
    /// parent-given frame), false for square detail grids.
    var fillsFrame = false

    @State private var confirmDelete = false
    @State private var deleteTargets: [FotoItem] = []
    @State private var isHovering = false

    var body: some View {
        ThumbnailCell(item: item, loader: loader, isSelected: isSelected, fillsFrame: fillsFrame)
            // Edge scrim so white overlays stay legible over bright photos.
            .overlay { if isHovering || isSelected { edgeScrim } }
            // Apple-Photos-style selection indicator (top-leading).
            .overlay(alignment: .topLeading) { selectionIndicator }
            // Stack badge (top-trailing) for collapsed similar-photo groups.
            .overlay(alignment: .topTrailing) { stackBadge }
            // Favorite heart quick-action (bottom-leading).
            .overlay(alignment: .bottomLeading) { heartControl }
            // Subtle lift on hover; keep the hovered cell above its neighbours.
            .scaleEffect(isHovering ? 1.03 : 1)
            .shadow(color: .black.opacity(isHovering ? 0.28 : 0), radius: 7, y: 3)
            .zIndex(isHovering ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .onHover { isHovering = $0 }
            .onTapGesture(count: 2, perform: onDoubleClick)
            .onTapGesture(perform: onClick)
            .task { await onAppear() }
            // Drag out to Finder → downloads the original (plan D2).
            .onDrag {
                guard let service = model.fotoService else { return NSItemProvider() }
                return FinderExport.itemProvider(for: item, service: service)
            }
            .contextMenu {
                let items = targets()
                Button {
                    Task { await model.toggleFavorite(items) }
                } label: {
                    let allFav = items.allSatisfy { model.isFavorite($0) }
                    Label(allFav ? "즐겨찾기 해제" : "즐겨찾기",
                          systemImage: allFav ? "heart.slash" : "heart")
                }
                Button {
                    Task { await model.downloadItems(items) }
                } label: {
                    Label(items.count > 1 ? "\(items.count)개 다운로드" : "원본 다운로드",
                          systemImage: "arrow.down.circle")
                }
                AddToAlbumMenu(items: items)
                if let extra = extraAction, extra.allowsMultiple || items.count == 1 {
                    Button {
                        extra.run(items)
                    } label: {
                        Label(extra.allowsMultiple && items.count > 1 ? "\(items.count)개 \(extra.title)" : extra.title,
                              systemImage: extra.systemImage)
                    }
                }
                Divider()
                Button(role: .destructive) {
                    deleteTargets = items
                    confirmDelete = true
                } label: {
                    Label(items.count > 1 ? "\(items.count)개 삭제" : "삭제", systemImage: "trash")
                }
                if isSelected {
                    Divider()
                    Button("선택 해제", action: onDeselect)
                }
            }
            .confirmationDialog(
                deleteTargets.count > 1 ? "선택한 \(deleteTargets.count)장을 삭제하시겠습니까?" : "이 사진을 삭제하시겠습니까?",
                isPresented: $confirmDelete, titleVisibility: .visible
            ) {
                Button("삭제", role: .destructive) {
                    let d = deleteTargets
                    Task { await model.deleteItems(d) }
                }
                Button("취소", role: .cancel) {}
            } message: {
                Text("Synology Photos에는 휴지통이 없어 복구할 수 없습니다.")
            }
    }

    /// Soft top+bottom darkening so the white selection/heart controls read over
    /// any photo. Shown only while hovering or selected.
    private var edgeScrim: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.28), location: 0),
                .init(color: .clear, location: 0.28),
                .init(color: .clear, location: 0.72),
                .init(color: .black.opacity(0.28), location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .allowsHitTesting(false)
    }

    /// Count badge for a collapsed similar-photo stack (Synology-style).
    @ViewBuilder
    private var stackBadge: some View {
        if item.isStack {
            HStack(spacing: 3) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 9))
                Text("\(item.stackCount)").font(.caption2).monospacedDigit()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.black.opacity(0.55), in: Capsule())
            .shadow(color: .black.opacity(0.35), radius: 1.5)
            .padding(5)
        }
    }

    /// A ring that appears on hover and fills with a check when selected — a
    /// pure indicator; selection itself is driven by the cell's click handling.
    @ViewBuilder
    private var selectionIndicator: some View {
        if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.accentColor)
                .font(.title3)
                .shadow(color: .black.opacity(0.35), radius: 2)
                .padding(6)
        } else if isHovering {
            Image(systemName: "circle")
                .foregroundStyle(.white.opacity(0.95))
                .font(.title3)
                .shadow(color: .black.opacity(0.45), radius: 2)
                .padding(6)
        }
    }

    /// Favorite toggle: a filled red heart when favorited (always visible), or a
    /// faint outline heart on hover to add. Native symbol bounce on change.
    @ViewBuilder
    private var heartControl: some View {
        let fav = model.isFavorite(item)
        if fav || isHovering {
            Button {
                Task { await model.toggleFavorite([item]) }
            } label: {
                Image(systemName: fav ? "heart.fill" : "heart")
                    .foregroundStyle(fav ? AnyShapeStyle(.red) : AnyShapeStyle(.white.opacity(0.95)))
                    .font(.body)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .symbolEffect(.bounce, value: fav)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(fav ? "즐겨찾기 해제" : "즐겨찾기")
        }
    }
}
