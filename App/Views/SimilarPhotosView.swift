import SwiftUI
import AppKit
import FotoKit

/// "유사한 항목 정리" — Synology's similar-photo groups (bursts / near-dupes),
/// each with a recommended keeper. The user keeps some and deletes the rest,
/// reclaiming space. Every deletion is explicit and confirmed.
struct SimilarPhotosView: View {
    @Environment(AppModel.self) private var model
    let vm: SimilarPhotosViewModel

    @State private var pendingDelete: SimilarPhotosViewModel.Group?

    var body: some View {
        Group {
            if vm.groups.isEmpty && vm.isLoading {
                ProgressView("유사한 사진을 찾는 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = vm.errorMessage, vm.groups.isEmpty {
                ContentUnavailableView("불러오기 실패", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if vm.activeGroupCount == 0 {
                ContentUnavailableView {
                    Label("정리할 유사 사진 없음", systemImage: "checkmark.seal")
                } description: {
                    Text("비슷한 사진 묶음이 없습니다. 라이브러리가 깔끔하네요.")
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 20) {
                        ForEach(vm.groups.filter { !$0.isDismissed }) { group in
                            GroupCard(group: group, vm: vm, onDelete: { pendingDelete = group })
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("유사한 항목 정리")
        .navigationSubtitle(vm.activeGroupCount > 0 ? "\(vm.activeGroupCount)개 묶음 · 최대 \(vm.totalRemovable)장 정리 가능" : "")
        .task { await vm.loadIfNeeded() }
        .confirmationDialog(
            "선택한 사진을 삭제할까요?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { group in
            Button("\(group.removeCount)장 삭제", role: .destructive) {
                let g = group
                Task {
                    if let deleted = await vm.applyDeletion(g), !deleted.isEmpty {
                        model.registerExternalDeletion(deleted)
                        model.showInfo("\(deleted.count)장을 삭제했습니다.")
                    } else if vm.errorMessage != nil {
                        model.showError(vm.errorMessage ?? "삭제 실패")
                    }
                }
                pendingDelete = nil
            }
            Button("취소", role: .cancel) { pendingDelete = nil }
        } message: { group in
            Text("보관으로 표시한 \(group.keptIDs.count)장은 남고, 나머지 \(group.removeCount)장이 영구 삭제됩니다. Synology Photos에는 휴지통이 없어 되돌릴 수 없습니다.")
        }
    }
}

/// One similar-photo group: a header with the reclaim count + actions, and a row
/// of member thumbnails the user toggles between keep and delete.
private struct GroupCard: View {
    @Bindable var group: SimilarPhotosViewModel.Group
    let vm: SimilarPhotosViewModel
    let onDelete: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 150), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(group.meta.count)장이 비슷해요").font(.headline)
                Spacer()
                Text(group.removeCount > 0 ? "\(group.removeCount)장 삭제 · \(group.keptIDs.count)장 보관" : "모두 보관")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if group.isResolved {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(group.members) { item in
                        MemberThumb(
                            item: item,
                            loader: vm.thumbnailLoader,
                            isKept: group.keptIDs.contains(item.id),
                            isTopPick: group.isTopPick(item.id),
                            onToggle: { vm.toggleKeep(item, in: group) }
                        )
                    }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).frame(height: 120)
            }

            HStack {
                Button("추천대로", systemImage: "wand.and.stars") { vm.keepTopPickOnly(group) }
                    .help("Synology 추천 사진만 남기고 나머지를 삭제 표시")
                Button("모두 보관") { vm.dismiss(group) }
                Spacer()
                Button("삭제", systemImage: "trash", role: .destructive, action: onDelete)
                    .buttonStyle(.borderedProminent)
                    .disabled(group.removeCount == 0)
            }
            .controlSize(.small)
        }
        .dsCard(padding: DS.s3)
        .task(id: group.id) { await vm.resolve(group) }
    }
}

/// A member thumbnail with a keep/delete state. Kept = accent ring + check;
/// to-delete = dimmed. The top pick carries a "추천" badge.
private struct MemberThumb: View {
    let item: FotoItem
    let loader: ThumbnailLoader
    let isKept: Bool
    let isTopPick: Bool
    let onToggle: () -> Void

    @State private var image: NSImage?

    var body: some View {
        Button(action: onToggle) {
            Rectangle()
                .fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .overlay { if !isKept { Color.black.opacity(0.45) } }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if isTopPick {
                        Text("추천")
                            .font(.caption2).bold()
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.yellow, in: Capsule())
                            .foregroundStyle(.black)
                            .padding(5)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: isKept ? "checkmark.circle.fill" : "trash.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isKept ? Color.accentColor : Color.red)
                        .padding(5)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isKept ? Color.accentColor : .clear, lineWidth: 2.5)
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(isKept ? "보관 (클릭하면 삭제 표시)" : "삭제 표시 (클릭하면 보관)")
        .task(id: item.id) { image = await loader.image(for: item, size: .m) }
    }
}
