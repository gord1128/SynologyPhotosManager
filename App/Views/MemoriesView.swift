import SwiftUI
import FotoKit

/// "추억" — today's month-day in previous years, as horizontal per-year strips
/// (Google Photos Memories / Apple Photos "추억"). A rediscovery surface: tap a
/// photo for the full-screen preview (navigates within that year). Management
/// (delete/organize) stays on the timeline — keep this view calm.
struct MemoriesView: View {
    @Environment(AppModel.self) private var model
    @Bindable var vm: MemoriesViewModel

    /// The year-group currently open in the preview + the index within it.
    @State private var previewItems: [FotoItem] = []
    @State private var previewIndex = 0

    private var previewItem: FotoItem? {
        previewItems.indices.contains(previewIndex) ? previewItems[previewIndex] : nil
    }

    var body: some View {
        ZStack {
            content
            if let item = previewItem {
                PhotoPreviewView(
                    item: item, loader: vm.thumbnailLoader,
                    onClose: { previewItems = [] },
                    onPrev: { if previewIndex > 0 { previewIndex -= 1 } },
                    onNext: { if previewIndex < previewItems.count - 1 { previewIndex += 1 } }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: previewItem?.id)
        .navigationTitle("추억")
        .task { await vm.loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if vm.groups.isEmpty && vm.isLoading {
            ProgressView("추억을 찾는 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.groups.isEmpty {
            ContentUnavailableView(
                "오늘의 추억이 없습니다",
                systemImage: "sparkles",
                description: Text("\(vm.todayLabel), 지난 해에 찍은 사진이 없습니다."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.s5) {
                    Text("\(vm.todayLabel)의 추억")
                        .font(.title2.weight(.semibold))
                        .padding(.horizontal, DS.s4).padding(.top, DS.s3)
                    ForEach(vm.groups) { group in yearRow(group) }
                }
                .padding(.bottom, DS.s5)
            }
        }
    }

    private func yearRow(_ group: MemoriesViewModel.YearGroup) -> some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            HStack(alignment: .firstTextBaseline, spacing: DS.s2) {
                Text(group.title).font(.headline)
                Text("\(String(group.year))년 · \(group.items.count)장")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, DS.s4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.s2) {
                    ForEach(Array(group.items.enumerated()), id: \.element.id) { idx, item in
                        ThumbnailCell(item: item, loader: vm.thumbnailLoader, isSelected: false)
                            .frame(width: 160, height: 160)
                            .onTapGesture {
                                previewItems = group.items
                                previewIndex = idx
                            }
                    }
                }
                .padding(.horizontal, DS.s4)
            }
        }
    }
}
