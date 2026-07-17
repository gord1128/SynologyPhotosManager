import SwiftUI
import AppKit
import FotoKit

/// Folder browser: breadcrumb + subfolder tiles + the current folder's photos.
struct FolderBrowserView: View {
    let model: FolderViewModel
    var onActivate: () -> Void = {}

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 200), spacing: 2)]
    private let folderColumns = [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
            Divider()
            content
        }
        .navigationTitle(model.path.last?.displayName ?? "폴더")
        .task { await model.loadIfNeeded() }
    }

    private func handleClick(_ item: FotoItem) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) { model.toggle(item.id) }
        else if flags.contains(.shift) { model.selectRange(to: item.id) }
        else if model.selectedIDs == [item.id] { model.clearSelection() }
        else { model.selectSingle(item.id) }
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button("홈") { Task { await model.navigate(to: nil) } }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                ForEach(Array(model.path.enumerated()), id: \.element.id) { index, folder in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Button(folder.displayName) { Task { await model.navigate(to: index) } }
                        .buttonStyle(.plain)
                        .foregroundStyle(index == model.path.count - 1 ? .primary : .secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.subfolders.isEmpty && model.items.isEmpty {
            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("빈 폴더", systemImage: "folder")
            }
        } else {
            ScrollView {
                if !model.subfolders.isEmpty {
                    LazyVGrid(columns: folderColumns, spacing: 8) {
                        ForEach(model.subfolders) { folder in
                            folderTile(folder)
                        }
                    }
                    .padding(8)
                    if !model.items.isEmpty { Divider() }
                }
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(model.items) { item in
                        SelectablePhotoCell(
                            item: item,
                            loader: model.thumbnailLoader,
                            isSelected: model.selectedIDs.contains(item.id),
                            targets: { model.selectedIDs.contains(item.id) ? model.selectedItems : [item] },
                            onClick: { handleClick(item) },
                            onDoubleClick: { model.selectSingle(item.id); onActivate() },
                            onDeselect: { model.clearSelection() },
                            onAppear: { if model.shouldLoadMore(after: item) { await model.loadMore() } }
                        )
                    }
                }
                .padding(2)
                if model.isLoading && !model.items.isEmpty {
                    ProgressView().controlSize(.small).padding()
                }
            }
            .onTapGesture { model.clearSelection() }
        }
    }

    private func folderTile(_ folder: FotoFolder) -> some View {
        Button {
            Task { await model.open(folder) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                Text(folder.displayName).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
