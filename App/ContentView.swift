import SwiftUI
import SynoKit
import FotoKit

/// The main 3-pane layout (plan §5): sidebar · grid/timeline · inspector.
struct ContentView: View {
    @Environment(AppModel.self) private var model

    @State private var library: LibraryViewModel?
    @State private var folders: FolderViewModel?
    @State private var albums: AlbumsViewModel?
    @State private var people: PeopleViewModel?
    @State private var similar: SimilarPhotosViewModel?
    @State private var recent: ItemGridViewModel?
    @State private var triage: TriageViewModel?
    @State private var memories: MemoriesViewModel?
    @State private var mapVM: MapViewModel?
    @State private var showingAdd = false
    @State private var showingPreview = false

    /// Which grid ContentView itself owns. Every other destination (앨범, 사람,
    /// 지도, 추억, 정리, 최근 추가) manages its own selection inside its view,
    /// so ContentView must claim NOTHING there.
    ///
    /// The old `== .folders ? folders : library` fell through to `library` for
    /// EVERY other sidebar item, so a photo selected on the timeline kept its
    /// info panel open over the 사람 grid, and Space/←/→ still drove the hidden
    /// timeline selection from screens that have nothing to do with it.
    private enum OwnedGrid { case timeline, folders, none }
    private var ownedGrid: OwnedGrid {
        switch model.selectedSidebarItem {
        case .folders: return .folders
        case .timeline, .none: return .timeline
        default: return .none
        }
    }

    /// The selection currently feeding the inspector + preview.
    private var activeItem: FotoItem? {
        switch ownedGrid {
        case .timeline: return library?.selectedItem
        case .folders: return folders?.selectedItem
        case .none: return nil
        }
    }
    private var activeLoader: ThumbnailLoader? {
        switch ownedGrid {
        case .timeline: return library?.thumbnailLoader
        case .folders: return folders?.thumbnailLoader
        case .none: return nil
        }
    }
    private func activeSelectPrevious() {
        switch ownedGrid {
        case .timeline: library?.selectPrevious()
        case .folders: folders?.selectPrevious()
        case .none: break
        }
    }
    private func activeSelectNext() {
        switch ownedGrid {
        case .timeline: library?.selectNext()
        case .folders: folders?.selectNext()
        case .none: break
        }
    }
    private func activeClearSelection() {
        switch ownedGrid {
        case .timeline: library?.clearSelection()
        case .folders: folders?.clearSelection()
        case .none: break
        }
    }
    private var activeHasSelection: Bool {
        switch ownedGrid {
        case .timeline: return !(library?.selectedIDs.isEmpty ?? true)
        case .folders: return !(folders?.selectedIDs.isEmpty ?? true)
        case .none: return false
        }
    }

    var body: some View {
        @Bindable var model = model
        ZStack {
            splitView
            infoPanel
            noticeBanner
            if showingPreview, let item = activeItem, let loader = activeLoader {
                PhotoPreviewView(
                    item: item, loader: loader,
                    onClose: { showingPreview = false },
                    onPrev: { activeSelectPrevious() },
                    onNext: { activeSelectNext() }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showingPreview)
        .animation(.easeInOut(duration: 0.22), value: activeItem?.id)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) { togglePreview() }
        .onKeyPress(.leftArrow) { activeSelectPrevious(); return activeItem == nil ? .ignored : .handled }
        .onKeyPress(.rightArrow) { activeSelectNext(); return activeItem == nil ? .ignored : .handled }
        .onKeyPress(.escape) {
            if showingPreview { showingPreview = false; return .handled }
            if activeHasSelection { activeClearSelection(); return .handled }
            return .ignored
        }
    }

    /// Info panel for the timeline / folder grids. Album, person, stack and
    /// map-cluster grids get the same panel from inside `DetailGridView`.
    @ViewBuilder
    private var infoPanel: some View {
        if let item = activeItem, !showingPreview {
            PhotoInspectorPanel(item: item, loader: activeLoader) { activeClearSelection() }
        }
    }

    /// Banner for errors (persist until dismissed) and brief confirmations
    /// (auto-clear). Fed by `AppModel.showError/showInfo`.
    ///
    /// It rides directly ABOVE the bottom chrome bar, at the same width, so the
    /// screen has one floating stack instead of a banner at the top and a bar
    /// at the bottom arguing over the user's attention (design handoff §1a).
    @ViewBuilder
    private var noticeBanner: some View {
        if let notice = model.notice {
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: notice.kind == .error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(notice.kind == .error ? DS.danger : DS.ok)
                    Text(notice.message).font(.callout).lineLimit(2)
                    Spacer(minLength: 0)
                    Button {
                        model.notice = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .frame(width: ChromeBar<EmptyView>.width)
                .background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: DS.rPopover, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.rPopover, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.45), DS.hairline],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                .padding(.bottom, bannerBottomInset)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.2), value: model.notice)
        }
    }

    /// Clears the chrome bar on screens that have one; otherwise sits on the
    /// same 24pt baseline the bar would use.
    private var bannerBottomInset: CGFloat {
        let base = ChromeBar<EmptyView>.baseline
        guard ownedGrid == .timeline, !(library?.items.isEmpty ?? true) else { return base }
        return base + ChromeBar<EmptyView>.height + 8
    }

    private func togglePreview() -> KeyPress.Result {
        guard activeItem != nil else { return .ignored }
        showingPreview.toggle()
        return .handled
    }

    private var splitView: some View {
        @Bindable var model = model
        return NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            centerPane.background(DS.content)
        }
        .toolbar {
            // Only offer the 개인/공유 toggle when the shared space is actually
            // usable (probed at connect) — its API can exist while disabled (801).
            if model.sharedSpaceUsable {
                ToolbarItem(placement: .navigation) {
                    Picker("공간", selection: $model.space) {
                        ForEach(FotoSpace.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .help("개인 / 공유 공간 전환")
                }
            }
            // Primary action → rightmost trailing on every view (macOS HIG).
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.pickAndUpload() }
                } label: {
                    if model.isUploading {
                        Label("업로드 \(model.uploadDone)/\(model.uploadTotal)", systemImage: "arrow.up.circle")
                    } else {
                        // `photo.badge.plus` reads as "add photos" — NOT the macOS
                        // share glyph (`square.and.arrow.up`), which looked like 공유.
                        Label("업로드", systemImage: "photo.badge.plus")
                    }
                }
                .disabled(model.fotoService == nil || model.isUploading)
                .help("사진을 타임라인에 업로드")
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddConnectionView().environment(model)
        }
        .sheet(item: $model.pendingCertificate) { challenge in
            CertificateTrustView(challenge: challenge).environment(model)
        }
        .sheet(item: $model.exportRequest) { request in
            ExportOptionsView(items: request.items).environment(model)
        }
        // Create/tear down the VMs as the connection changes.
        .task(id: model.fotoService.map(ObjectIdentifier.init)) {
            if let service = model.fotoService {
                let lib = LibraryViewModel(service: service)
                library = lib
                folders = FolderViewModel(service: service)
                albums = AlbumsViewModel(service: service)
                people = PeopleViewModel(service: service)
                similar = SimilarPhotosViewModel(service: service)
                recent = ItemGridViewModel(loader: lib.thumbnailLoader) { offset, limit in
                    try await service.recentlyAdded(offset: offset, limit: limit)
                }
                triage = TriageViewModel(service: service)
                memories = MemoriesViewModel(service: service)
                mapVM = MapViewModel(service: service)
                await lib.loadInitial()
                #if SMOKE
                // Dev hook: pre-select the first item so the inspector can be
                // screenshotted headlessly. Read from UserDefaults (set via
                // `defaults write`) — survives an `open` launch, unlike env vars,
                // and needs no Accessibility permission. Debug builds only.
                if UserDefaults.standard.bool(forKey: "PHOTOS_AUTOSELECT"),
                   let first = lib.items.first(where: { !$0.isStack }) ?? lib.items.first {
                    lib.selectSingle(first.id)
                }
                #endif
            } else {
                library = nil
                folders = nil
                albums = nil
                people = nil
                similar = nil
                recent = nil
                triage = nil
                memories = nil
                mapVM = nil
            }
        }
        // Reload when the user switches personal/shared space.
        .onChange(of: model.space) {
            // Filter selections are id-based and space-specific (person_id etc.),
            // so drop them before reloading — otherwise the new space is queried
            // with the old space's invalid ids (wrong / empty results). See B1.
            library?.resetFilterSelections()
            Task { await library?.reload() }
            Task { await folders?.navigate(to: nil) }
            Task { await albums?.reload() }
            Task { await people?.reload() }
            Task { await similar?.reload() }
            Task { await recent?.reload() }
            // Triage is a fresh keep/delete pass per space — recreate it so the
            // new space's items (and no carried-over decisions) drive the cards.
            if let service = model.fotoService { triage = TriageViewModel(service: service) }
            Task { await memories?.reload() }
            Task { await mapVM?.reload() }
        }
        // Silent reconnect on launch if a credential is stored.
        .task { await model.connectSavedIfPossible() }
        // Refresh views after an upload (new items → full reload).
        .onChange(of: model.mutationCounter) {
            Task { await library?.reload() }
            Task { await folders?.reload() }
            Task { await albums?.reload() }
            Task { await people?.reload() }
        }
        // Deletions are applied locally so the scroll position is preserved;
        // only the cheap album/people lists re-fetch (their counts changed).
        .onChange(of: model.deletionCounter) {
            library?.removeItems(ids: model.deletedIDs)
            folders?.removeItems(ids: model.deletedIDs)
            triage?.applyCommitted(deletedIDs: model.deletedIDs)
            Task { await albums?.reload() }
            Task { await people?.reload() }
        }
        // Navigating away closes the preview: it is a full-window overlay, and
        // leaving it up over a different screen is the same leak as the panel.
        .onChange(of: model.selectedSidebarItem) { showingPreview = false }
        // Route main-menu commands to whichever center view is active.
        .onChange(of: model.menuCommandCounter) { dispatchMenuCommand() }
        // Opening a smart album (from the sidebar) applies its saved filter to the
        // timeline — the LibraryViewModel lives here, so apply it here.
        .onChange(of: model.applyCriteriaCounter) {
            if let criteria = model.pendingCriteria { library?.apply(criteria) }
        }
    }

    /// Applies a menu command (from `AppModel`'s bus) to the active view. Filter
    /// toggling is handled inside PhotoGridView (it owns the popover).
    private func dispatchMenuCommand() {
        guard let command = model.lastMenuCommand else { return }
        let onFolders = model.selectedSidebarItem == .folders
        switch command {
        case .selectAll:
            if onFolders { folders?.selectAll() } else { library?.selectAll() }
        case .deselectAll:
            if onFolders { folders?.clearSelection() } else { library?.clearSelection() }
        case .download:
            let items = onFolders ? (folders?.selectedItems ?? []) : (library?.selectedItems ?? [])
            if !items.isEmpty { Task { await model.downloadItems(items) } }
        case .export:
            let items = onFolders ? (folders?.selectedItems ?? []) : (library?.selectedItems ?? [])
            model.requestExport(items)
        case .delete:
            let items = onFolders ? (folders?.selectedItems ?? []) : (library?.selectedItems ?? [])
            if !items.isEmpty { Task { await model.deleteItems(items) } }
        case .scale(let scale):
            library?.setScale(scale)
        case .toggleFilter:
            break   // handled by PhotoGridView
        }
    }

    @ViewBuilder
    private var centerPane: some View {
        if model.selectedConnection == nil {
            ContentUnavailableView {
                Label("NAS를 추가하세요", systemImage: "externaldrive.badge.plus")
            } description: {
                Text("Synology NAS 연결을 추가하면 사진을 볼 수 있습니다.")
            } actions: {
                Button("연결 추가") { showingAdd = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if let library, model.fotoService != nil {
            switch model.selectedSidebarItem {
            case .timeline, .none:
                PhotoGridView(library: library, onActivate: { showingPreview = true })
            case .recent:
                if let recent {
                    DetailGridView(grid: recent, emptyMessage: "최근 추가된 항목 없음")
                        .navigationTitle("최근 추가")
                }
            case .folders:
                if let folders {
                    FolderBrowserView(model: folders, onActivate: { showingPreview = true })
                }
            case .albums:
                if let albums {
                    AlbumsView(model: albums)
                }
            case .people:
                if let people {
                    PeopleView(model: people)
                }
            case .similar:
                if let similar {
                    SimilarPhotosView(vm: similar)
                }
            case .triage:
                if let triage {
                    TriageView(vm: triage)
                }
            case .memories:
                if let memories {
                    MemoriesView(vm: memories)
                }
            case .map:
                if let mapVM {
                    MapView(vm: mapVM)
                }
            }
        } else {
            connectingPane
        }
    }

    @ViewBuilder
    private var connectingPane: some View {
        switch model.connectionState {
        case .connecting:
            ProgressView("연결 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            // An update that loosened the Local Network grant reports itself as
            // "인터넷 연결이 오프라인" — the generic pane would send the user to
            // check their router. Name the real cause instead.
            if model.needsLocalNetworkReset {
                LocalNetworkResetView(
                    onRetry: { await model.reconnect() },
                    onDismiss: { model.dismissLocalNetworkReset() })
            } else {
                ContentUnavailableView {
                    Label("연결 실패", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("다시 연결") { Task { await model.reconnect() } }
                    Button("연결 편집") { showingAdd = true }
                }
            }
        default:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedSidebarItem) {
            Section("보관함") {
                ForEach([SidebarItem.timeline, .recent, .memories, .map, .folders, .albums, .people]) { item in
                    Label(item.title, systemImage: item.systemImage).tag(item)
                }
            }
            // "정리 › 유사한 항목" tab removed — the collapsed timeline now folds
            // similar photos into expandable stacks, absorbing its purpose. The
            // SimilarPhotos view/VM + `.similar` case are kept (unreached) so the
            // dedicated batch-cleanup screen can be restored later.
            Section("정리") {
                Label(SidebarItem.triage.title, systemImage: SidebarItem.triage.systemImage)
                    .tag(SidebarItem.triage)
            }
            // Saved timeline filters (T2). Opening one selects the timeline and
            // applies its filter; these rows aren't `SidebarItem` selections.
            if !model.currentSpaceSmartAlbums.isEmpty {
                Section("스마트 앨범") {
                    ForEach(model.currentSpaceSmartAlbums) { album in
                        Button {
                            model.openSmartAlbum(album)
                        } label: {
                            Label(album.name, systemImage: "line.3.horizontal.decrease.circle")
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("삭제", role: .destructive) { model.deleteSmartAlbum(album) }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(DS.sidebar)
        .safeAreaInset(edge: .bottom) { ConnectionStatusBar() }
    }
}

struct ConnectionStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: DS.s2) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(.white.opacity(0.15)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusText).font(.caption.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    if let sub = subLine {
                        Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, DS.s3)
            .padding(.vertical, DS.s2)
        }
        .background(DS.bar)
    }

    /// Host shown as a subtitle only when the primary line is a nickname.
    private var subLine: String? {
        guard case .connected = model.connectionState,
              model.selectedConnection?.nickname != nil else { return nil }
        return model.selectedConnection?.host
    }

    private var statusColor: Color {
        switch model.connectionState {
        case .connected: return .green
        case .connecting: return .yellow
        case .failed: return .red
        case .disconnected: return .secondary
        }
    }

    private var statusText: String {
        switch model.connectionState {
        case .connected: return model.selectedConnection?.nickname ?? model.selectedConnection?.host ?? "연결됨"
        case .connecting: return "연결 중…"
        case .failed: return "연결 실패"
        case .disconnected: return "연결 안 됨"
        }
    }
}

#Preview {
    ContentView().environment(AppModel())
}
