import SwiftUI
import AppKit
import FotoKit

/// "정리(Triage)" — a fast, one-card-at-a-time keep/delete pass over the timeline
/// (Slidebox / Google Photos "free up space" style), the centerpiece of the
/// app's "관리, 백업 아님" vision. Keyboard-first: → keep, ⌫ mark delete, ← undo.
/// Deletes are collected and committed together behind a single confirmation
/// (Synology Photos has no trash), reusing `AppModel.deleteItems` so every other
/// grid drops the same items locally.
struct TriageView: View {
    @Environment(AppModel.self) private var model
    @Bindable var vm: TriageViewModel

    @State private var cardImage: NSImage?
    @State private var showingCommitConfirm = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // While actively triaging, keep a running delete tally + commit at the
            // bottom. At the end the completion screen owns the commit button, so
            // suppress the bar there (avoids a duplicate confirmationDialog).
            if vm.deletePendingCount > 0 && !vm.isAtEnd { commitBar }
            Divider()
            actionBar
        }
        .navigationTitle("정리")
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .task { await vm.loadInitial() }
        .task(id: vm.current?.id) {
            cardImage = nil
            if let c = vm.current { cardImage = await vm.thumbnailLoader.image(for: c, size: .xl) }
        }
        .onKeyPress(.rightArrow) {
            guard vm.current != nil else { return .ignored }
            vm.keep(); return .handled
        }
        .onKeyPress(.leftArrow) {
            guard vm.canUndo else { return .ignored }
            vm.undo(); return .handled
        }
        .onKeyPress(.delete) {
            guard vm.current != nil else { return .ignored }
            vm.markDelete(); return .handled
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DS.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("정리").font(.headline)
                Text("한 장씩 넘기며 유지/삭제를 정하세요 · → 유지 · ⌫ 삭제 · ← 되돌리기")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: DS.s2) {
                stat("결정", vm.decidedCount, .secondary)
                stat("유지", vm.keptCount, .green)
                stat("삭제 예정", vm.deletePendingCount, .red)
            }
        }
        .padding(.horizontal, DS.s4).padding(.vertical, DS.s3)
    }

    private func stat(_ label: String, _ value: Int, _ tint: Color) -> some View {
        VStack(spacing: 0) {
            Text("\(value)").font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(minWidth: 56)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let message = vm.errorMessage, vm.items.isEmpty {
            ContentUnavailableView("불러오기 실패", systemImage: "exclamationmark.triangle", description: Text(message))
        } else if vm.items.isEmpty && vm.isLoading {
            ProgressView().controlSize(.large)
        } else if vm.isAtEnd {
            completion
        } else if let item = vm.current {
            card(item)
        } else {
            ProgressView().controlSize(.large)   // paging the next chunk
        }
    }

    private func card(_ item: FotoItem) -> some View {
        VStack(spacing: DS.s3) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.rCard, style: .continuous).fill(.quaternary)
                if let cardImage {
                    Image(nsImage: cardImage).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: DS.rCard, style: .continuous))
                } else {
                    ProgressView().controlSize(.small)
                }
                // Video badge, favorite heart — quick context while triaging.
                VStack {
                    HStack {
                        if item.type == .video, let label = item.videoDurationLabel {
                            Label(label, systemImage: "play.fill")
                                .font(.caption.weight(.semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.black.opacity(0.55), in: Capsule())
                        }
                        Spacer()
                        if model.isFavorite(item) {
                            Image(systemName: "heart.fill").foregroundStyle(.red)
                                .padding(6).background(.black.opacity(0.35), in: Circle())
                        }
                    }
                    Spacer()
                }
                .padding(DS.s3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(item.filename)
                .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .padding(DS.s4)
    }

    private var completion: some View {
        VStack(spacing: DS.s4) {
            Image(systemName: vm.deletePendingCount > 0 ? "checklist" : "checkmark.circle.fill")
                .font(.system(size: 52)).foregroundStyle(vm.deletePendingCount > 0 ? Color.accentColor : .green)
            Text(vm.deletePendingCount > 0 ? "정리를 끝냈습니다" : "정리 완료")
                .font(.title3.weight(.semibold))
            Text("유지 \(vm.keptCount)장 · 삭제 예정 \(vm.deletePendingCount)장")
                .font(.callout).foregroundStyle(.secondary)
            if vm.deletePendingCount > 0 {
                Button { showingCommitConfirm = true } label: {
                    Label("삭제 예정 \(vm.deletePendingCount)장 삭제", systemImage: "trash")
                }
                .buttonStyle(PrimaryActionButtonStyle(tint: .red))
                .fixedSize()
                .confirmationDialog("\(vm.deletePendingCount)장을 삭제하시겠습니까?",
                                    isPresented: $showingCommitConfirm, titleVisibility: .visible) {
                    Button("\(vm.deletePendingCount)장 삭제", role: .destructive) { commit() }
                    Button("취소", role: .cancel) {}
                } message: {
                    Text("Synology Photos에는 휴지통이 없어 복구할 수 없습니다.")
                }
            }
        }
        .padding(DS.s5)
    }

    // MARK: - Commit bar (persistent while there are pending deletes)

    private var commitBar: some View {
        HStack(spacing: DS.s3) {
            Image(systemName: "trash").foregroundStyle(.red)
            Text("삭제 예정 \(vm.deletePendingCount)장").font(.callout)
            Spacer()
            Button { showingCommitConfirm = true } label: {
                Text("지금 삭제").frame(minWidth: 88)
            }
            .buttonStyle(PrimaryActionButtonStyle(tint: .red))
            .fixedSize()
            .confirmationDialog("\(vm.deletePendingCount)장을 삭제하시겠습니까?",
                                isPresented: $showingCommitConfirm, titleVisibility: .visible) {
                Button("\(vm.deletePendingCount)장 삭제", role: .destructive) { commit() }
                Button("취소", role: .cancel) {}
            } message: {
                Text("Synology Photos에는 휴지통이 없어 복구할 수 없습니다.")
            }
        }
        .padding(.horizontal, DS.s4).padding(.vertical, DS.s2)
        .background(.bar)
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: DS.s3) {
            Button { vm.undo() } label: {
                Label("되돌리기", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .disabled(!vm.canUndo)

            Button { vm.markDelete() } label: {
                Label("삭제", systemImage: "trash")
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .disabled(vm.current == nil)

            if let item = vm.current {
                AddToAlbumMenu(items: [item])
            }

            Button { vm.keep() } label: {
                Label("유지", systemImage: "checkmark")
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .disabled(vm.current == nil)
        }
        .controlSize(.large)
        .padding(DS.s4)
    }

    private func commit() {
        let pending = vm.pendingDeleteItems
        guard !pending.isEmpty else { return }
        // Delete via AppModel: it shows the toast and publishes `deletedIDs`, and
        // ContentView routes that back to `vm.applyCommitted` (same path every
        // other grid uses), so the cursor + counts update in one place.
        Task { await model.deleteItems(pending) }
    }
}
