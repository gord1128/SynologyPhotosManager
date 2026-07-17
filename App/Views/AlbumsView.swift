import SwiftUI
import AppKit
import FotoKit

/// Albums screen: a grid of album cards with create + delete, drilling into an
/// album's photos.
struct AlbumsView: View {
    let model: AlbumsViewModel

    @State private var showingCreate = false
    @State private var newName = ""
    @State private var duplicateName: String?
    @State private var renamingAlbum: FotoAlbum?
    @State private var renameInput = ""

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)]

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("앨범")
                .toolbar {
                    ToolbarItem {
                        Button { showingCreate = true } label: { Label("새 앨범", systemImage: "plus") }
                    }
                }
                .navigationDestination(for: FotoAlbum.self) { album in
                    AlbumDetailView(album: album, service: model.service, loader: model.thumbnailLoader)
                }
        }
        .task { await model.loadIfNeeded() }
        .alert("새 앨범", isPresented: $showingCreate) {
            TextField("앨범 이름", text: $newName)
            Button("만들기") {
                let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                newName = ""
                guard !n.isEmpty else { return }
                // Same-named album already exists → confirm before duplicating.
                if model.albums.contains(where: { $0.name == n }) {
                    duplicateName = n
                } else {
                    Task { await model.createAlbum(named: n) }
                }
            }
            Button("취소", role: .cancel) { newName = "" }
        }
        .confirmationDialog(
            "같은 이름의 앨범이 이미 있습니다",
            isPresented: Binding(get: { duplicateName != nil }, set: { if !$0 { duplicateName = nil } }),
            presenting: duplicateName
        ) { name in
            Button("그래도 만들기") {
                Task { await model.createAlbum(named: name) }
                duplicateName = nil
            }
            Button("취소", role: .cancel) { duplicateName = nil }
        } message: { name in
            Text("‘\(name)’ 앨범이 이미 있습니다. 같은 이름으로 하나 더 만들까요?")
        }
        .alert("앨범 이름 변경", isPresented: Binding(get: { renamingAlbum != nil }, set: { if !$0 { renamingAlbum = nil } }), presenting: renamingAlbum) { album in
            TextField("이름", text: $renameInput)
            Button("저장") {
                let name = renameInput
                Task { await model.rename(album, to: name) }
                renamingAlbum = nil
            }
            Button("취소", role: .cancel) { renamingAlbum = nil }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.albums.isEmpty && model.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.albums.isEmpty {
            ContentUnavailableView {
                Label("앨범 없음", systemImage: "rectangle.stack.badge.plus")
            } description: {
                Text("사진을 모아 앨범을 만들어 보세요.")
            } actions: {
                Button("새 앨범") { showingCreate = true }.buttonStyle(.borderedProminent)
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(model.albums) { album in
                        NavigationLink(value: album) {
                            AlbumCard(album: album, loader: model.thumbnailLoader)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("이름 변경", systemImage: "pencil") {
                                renameInput = album.name
                                renamingAlbum = album
                            }
                            Divider()
                            Button("삭제", role: .destructive) { Task { await model.delete(album) } }
                        }
                    }
                }
                .padding()
            }
        }
    }
}

private struct AlbumCard: View {
    let album: FotoAlbum
    let loader: ThumbnailLoader

    @State private var cover: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: DS.rCard, style: .continuous)
                .fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let cover {
                        Image(nsImage: cover).resizable().scaledToFill()
                    } else {
                        Image(systemName: "rectangle.stack").font(.largeTitle).foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: DS.rCard, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.rCard, style: .continuous).strokeBorder(DS.hairline))
            Text(album.name).font(.callout).lineLimit(1)
            Text("\(album.itemCount)장").font(.caption).foregroundStyle(.secondary)
        }
        .task(id: album.id) {
            if let thumb = album.additional?.thumbnail {
                cover = await loader.image(thumbnail: thumb, size: .m)
            }
        }
    }
}

/// A single album's photos: paginated grid with the standard selection/preview/
/// right-click behaviour, plus "앨범에서 제거" and renaming the album.
struct AlbumDetailView: View {
    @Environment(AppModel.self) private var model
    let album: FotoAlbum
    let service: FotoService
    let loader: ThumbnailLoader

    @State private var grid: ItemGridViewModel?
    @State private var renaming = false
    @State private var nameInput = ""
    @State private var title: String

    init(album: FotoAlbum, service: FotoService, loader: ThumbnailLoader) {
        self.album = album
        self.service = service
        self.loader = loader
        _title = State(initialValue: album.name)
    }

    var body: some View {
        Group {
            if let grid {
                DetailGridView(
                    grid: grid,
                    extraAction: .init(title: "앨범에서 제거", systemImage: "rectangle.stack.badge.minus") { items in
                        Task { await removeFromAlbum(items, grid: grid) }
                    },
                    emptyMessage: "빈 앨범"
                )
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem {
                Button {
                    nameInput = title
                    renaming = true
                } label: {
                    Label("이름 변경", systemImage: "pencil")
                }
            }
        }
        .alert("앨범 이름 변경", isPresented: $renaming) {
            TextField("이름", text: $nameInput)
            Button("저장") {
                let name = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name != title else { return }
                Task {
                    do {
                        try await service.renameAlbum(id: album.id, name: name)
                        title = name
                        model.showInfo("앨범 이름을 변경했습니다.")
                    } catch {
                        model.showError("이름 변경 실패: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
                    }
                }
            }
            Button("취소", role: .cancel) {}
        }
        .task {
            if grid == nil {
                grid = ItemGridViewModel(loader: loader) { offset, limit in
                    try await service.items(inAlbum: album.id, offset: offset, limit: limit)
                }
            }
        }
    }

    private func removeFromAlbum(_ items: [FotoItem], grid: ItemGridViewModel) async {
        do {
            try await service.removeItems(albumId: album.id, itemIds: items.map(\.id))
            grid.removeItems(ids: Set(items.map(\.id)))
            model.showInfo(items.count > 1 ? "\(items.count)장을 앨범에서 제거했습니다." : "앨범에서 제거했습니다.")
        } catch {
            model.showError("앨범에서 제거 실패: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        }
    }
}
