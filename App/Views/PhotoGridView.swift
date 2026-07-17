import SwiftUI
import AppKit
import FotoKit

/// The main thumbnail grid. Virtualized via `LazyVGrid`, paginates by loading
/// the next page as the user nears the end of the loaded window.
struct PhotoGridView: View {
    @Environment(AppModel.self) private var model
    let library: LibraryViewModel
    /// Called when a cell is double-clicked — opens Quick Look.
    var onActivate: () -> Void = {}

    @State private var isDropTargeted = false
    @State private var showingFilters = false
    /// The stack the user tapped open (its similar photos are shown in a sheet).
    @State private var openStack: FotoItem?

    /// Target row height for the justified layout (연/월/일 changes density).
    private var rowHeight: CGFloat { library.scale.cellMin }

    private var subtitle: String {
        if library.hasActiveFilter { return "\(library.items.count.formatted())개 · 필터 적용됨" }
        return library.totalCount > 0 ? "\(library.totalCount.formatted())장" : ""
    }

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp", "raw", "dng", "arw", "cr2", "nef", "mp4", "mov", "m4v",
    ]

    var body: some View {
        Group {
            if library.items.isEmpty && library.isLoading {
                ProgressView("불러오는 중…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = library.errorMessage, library.items.isEmpty {
                ContentUnavailableView("불러오기 실패", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if library.items.isEmpty {
                ContentUnavailableView("사진 없음", systemImage: "photo.on.rectangle")
            } else {
                GeometryReader { geo in
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                                ForEach(library.sections) { section in
                                    Section {
                                        justifiedRows(section, width: geo.size.width - 4)
                                    } header: {
                                        sectionHeader(section)
                                    }
                                    .id(section.id)
                                }
                            }
                            .padding(2)
                            if library.isLoading && !library.items.isEmpty {
                                ProgressView().controlSize(.small).padding()
                            }
                        }
                        // Click empty space to deselect (cell taps take priority).
                        .onTapGesture { library.clearSelection() }
                        .overlay(alignment: .trailing) { yearRail(proxy) }
                    }
                }
            }
        }
        .navigationTitle("타임라인")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button {
                    showingFilters = true
                } label: {
                    let n = library.activeFilterCount
                    Label(n == 0 ? "필터" : "필터 \(n)",
                          systemImage: n == 0 ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .help("사진을 종류·날짜·사람·장소로 필터링")
                .popover(isPresented: $showingFilters, arrowEdge: .bottom) {
                    FilterPanel(library: library)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if !library.items.isEmpty {
                scaleSwitcher.padding(.bottom, 14)
            }
        }
        .sheet(item: $openStack) { rep in
            StackDetailView(rep: rep, service: library.service, loader: library.thumbnailLoader)
        }
        // View → 필터… (⌘F) opens the filter popover from the menu.
        .onChange(of: model.menuCommandCounter) {
            if model.lastMenuCommand == .toggleFilter { showingFilters.toggle() }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let images = urls.filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
            guard !images.isEmpty else { return false }
            Task { await model.upload(images) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .overlay { Label("여기에 놓아 업로드", systemImage: "square.and.arrow.down").font(.title2).padding().background(.regularMaterial, in: Capsule()) }
                    .allowsHitTesting(false)
            }
        }
    }

    /// Justified rows for one date section — photos keep their aspect ratio and
    /// each row fills the width (Google Photos / Apple "Aspect Ratio" style).
    @ViewBuilder
    private func justifiedRows(_ section: TimelineSection, width: CGFloat) -> some View {
        let rows = JustifiedLayout.rows(section.items, width: width, targetHeight: rowHeight, gap: 2)
        ForEach(rows) { row in
            HStack(spacing: 2) {
                ForEach(row.tiles) { tile in
                    photoCell(tile.item)
                        .frame(width: tile.width, height: tile.height)
                }
            }
        }
    }

    private func photoCell(_ item: FotoItem) -> some View {
        SelectablePhotoCell(
            item: item,
            loader: library.thumbnailLoader,
            isSelected: library.selectedIDs.contains(item.id),
            targets: { library.selectedIDs.contains(item.id) ? library.selectedItems : [item] },
            onClick: { handleClick(item) },
            onDoubleClick: { library.selectSingle(item.id); onActivate() },
            onDeselect: { library.clearSelection() },
            onAppear: { if library.shouldLoadMore(after: item) { await library.loadMore() } },
            fillsFrame: true
        )
    }

    /// Modifier-aware click: ⌘ toggles, ⇧ extends a range, plain selects one —
    /// and clicking the sole-selected item again deselects it (standard toggle).
    /// A plain click on a stack opens it (Synology-style); ⌘/⇧ still select it.
    private func handleClick(_ item: FotoItem) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) { library.toggle(item.id) }
        else if flags.contains(.shift) { library.selectRange(to: item.id) }
        else if item.isStack { openStack = item }
        else if library.selectedIDs == [item.id] { library.clearSelection() }
        else { library.selectSingle(item.id) }
    }

    private func sectionHeader(_ section: TimelineSection) -> some View {
        HStack {
            Text(section.title).font(.headline)
            Text("\(section.items.count)").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    /// Right-edge year scrubber. Tapping a year jumps the timeline to its first
    /// section, loading further pages first if that year isn't loaded yet.
    @ViewBuilder
    private func yearRail(_ proxy: ScrollViewProxy) -> some View {
        let years = library.loadedYears
        if years.count > 1 {
            VStack(spacing: 2) {
                ForEach(years, id: \.self) { year in
                    Button {
                        Task {
                            await library.ensureYearLoaded(year)
                            if let id = library.firstSectionID(forYear: year) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo(id, anchor: .top)
                                }
                            }
                        }
                    } label: {
                        Text(String(format: "%d", year))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 3)
            .dsFloating()
            .padding(.trailing, 6)
            // Fade in only once there's a meaningful span loaded.
            .transition(.opacity)
        }
    }

    /// Floating 연도 / 월 / 일 granularity switcher (matches Synology Photos).
    private var scaleSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(TimelineScale.allCases) { scale in
                Button {
                    library.setScale(scale)
                } label: {
                    Text(scale.rawValue)
                        .font(.callout)
                        .fontWeight(library.scale == scale ? .semibold : .regular)
                        .foregroundStyle(library.scale == scale ? Color.primary : .secondary)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        .background { if library.scale == scale { Capsule().fill(.selection) } }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .dsFloating()
    }
}
