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
        VStack(spacing: DS.s3) {
            HStack(alignment: .lastTextBaseline, spacing: DS.s3) {
                Text("정리").font(.headline)
                Text("한 장씩 넘기며 유지할지 지울지 정합니다")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: DS.s4) {
                    stat("유지", vm.keptCount, DS.ok)
                    stat("삭제 예정", vm.deletePendingCount, DS.danger)
                    stat("남음", vm.remainingCount, .secondary)
                }
            }
            progressRail
        }
        .padding(.horizontal, DS.s4).padding(.top, DS.s3).padding(.bottom, DS.s3)
    }

    /// One cell per photo in the CURRENT ROUND — the rhythm of the pass, made
    /// visible. Scoped to a round because one cell per photo cannot describe a
    /// 2,000-photo library (design handoff §1c).
    private var progressRail: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                ForEach(Array(vm.railCells.enumerated()), id: \.offset) { _, cell in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color(for: cell))
                        .frame(height: 6)
                        .overlay {
                            if cell == .current {
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .stroke(Color.accentColor.opacity(0.35), lineWidth: 2)
                                    .padding(-2)
                            }
                        }
                }
            }
            HStack(spacing: 7) {
                Text("묶음 ") .font(.caption2).foregroundStyle(.secondary)
                    + Text("\(vm.roundIndex) / \(vm.roundCount)")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Text("이 묶음 ").font(.caption2).foregroundStyle(.tertiary)
                    + Text("\(vm.decidedInRound) / \(TriageViewModel.roundSize)")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("진행: 묶음 \(vm.roundIndex) / \(vm.roundCount), 이 묶음에서 \(vm.decidedInRound)장 결정")
    }

    private func color(for cell: TriageViewModel.RailCell) -> Color {
        switch cell {
        case .kept: return DS.ok
        case .deletePending: return DS.danger
        case .current: return .accentColor
        case .undecided: return Color.primary.opacity(0.12)
        case .beyond: return Color.primary.opacity(0.05)
        }
    }

    private func stat(_ label: String, _ value: Int, _ tint: Color) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("\(value)").font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let message = vm.errorMessage, vm.items.isEmpty {
            ContentUnavailableView("불러오기 실패", systemImage: "exclamationmark.triangle", description: Text(message))
        } else if vm.items.isEmpty && vm.isLoading {
            ProgressView().controlSize(.large)
        } else if vm.isEmptyLibrary {
            ContentUnavailableView("정리할 사진이 없습니다", systemImage: "tray",
                                   description: Text("이 공간에 사진이 없습니다. 사진을 올린 뒤 다시 열어 보세요."))
        } else if vm.isAtEnd {
            completion
        } else if let item = vm.current {
            card(item)
        } else {
            ProgressView().controlSize(.large)   // paging the next chunk
        }
    }

    /// A deck, not a single frame: the two cards behind are the photos still
    /// queued, so the screen says "there is more after this one" without a
    /// number. Design handoff §1c.
    private func card(_ item: FotoItem) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: DS.s3)
            ZStack {
                ghostCard(rotation: 4.5, scale: 0.94, opacity: vm.hasNext(offset: 2) ? 0.28 : 0)
                ghostCard(rotation: -2.5, scale: 0.97, opacity: vm.hasNext(offset: 1) ? 0.45 : 0)
                topCard(item)
            }
            .frame(maxWidth: 640, maxHeight: .infinity)

            VStack(spacing: 4) {
                Text(item.filename)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                Text(cardMeta(item))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, DS.s5)
            Spacer(minLength: DS.s3)
        }
        .padding(.horizontal, DS.s5)
        .animation(.easeOut(duration: 0.18), value: item.id)
    }

    private func ghostCard(rotation: Double, scale: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: DS.rCard, style: .continuous)
            .fill(DS.card)
            .overlay(RoundedRectangle(cornerRadius: DS.rCard, style: .continuous)
                .strokeBorder(DS.hairline))
            .rotationEffect(.degrees(rotation))
            .scaleEffect(scale)
            .opacity(opacity)
            .allowsHitTesting(false)
    }

    private func topCard(_ item: FotoItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.rCard, style: .continuous).fill(DS.card)
            if let cardImage {
                Image(nsImage: cardImage).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: DS.rCard, style: .continuous))
            } else {
                ProgressView().controlSize(.small)
            }
            VStack {
                HStack(spacing: DS.s2) {
                    if item.type == .video, let label = item.videoDurationLabel {
                        Label(label, systemImage: "play.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.black.opacity(0.55), in: Capsule())
                    }
                    Spacer()
                    // Per-photo actions belong WITH the photo. The action bar
                    // below answers one question — keep or delete — and a menu
                    // sitting in that row broke its keyboard-first rhythm.
                    HStack(spacing: 1) {
                        Button {
                            Task { await model.toggleFavorite([item]) }
                        } label: {
                            Image(systemName: model.isFavorite(item) ? "heart.fill" : "heart")
                                .foregroundStyle(model.isFavorite(item) ? AnyShapeStyle(DS.danger) : AnyShapeStyle(.white))
                                .symbolEffect(.bounce, value: model.isFavorite(item))
                                .frame(width: 27, height: 27)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(model.isFavorite(item) ? "즐겨찾기 해제" : "즐겨찾기")
                        AddToAlbumMenu(items: [item])
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.white)
                            .frame(width: 27, height: 27)
                    }
                    .padding(3)
                    .background(.black.opacity(0.5), in: Capsule())
                }
                Spacer()
            }
            .padding(DS.s3)
        }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }

    private func cardMeta(_ item: FotoItem) -> String {
        var parts = [item.takenAt.formatted(date: .numeric, time: .omitted),
                     ByteCountFormatter.string(fromByteCount: Int64(item.filesize), countStyle: .file)]
        if item.isStack { parts.append("유사 항목 \(item.stackCount)") }
        return parts.joined(separator: " · ")
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
                    Text("Synology Photos 안에는 휴지통이 없습니다. NAS 공유 폴더의 휴지통을 켜 두지 않았다면 되돌릴 수 없습니다.")
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
                Text("Synology Photos 안에는 휴지통이 없습니다. NAS 공유 폴더의 휴지통을 켜 두지 않았다면 되돌릴 수 없습니다.")
            }
        }
        .padding(.horizontal, DS.s4).padding(.vertical, DS.s2)
        .background(DS.bar)
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
