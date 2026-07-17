import SwiftUI
import AppKit
import FotoKit

/// People screen: a grid of recognized-person cards (circular face crops, like
/// Synology Photos), drilling into each person's photos.
struct PeopleView: View {
    let model: PeopleViewModel

    @State private var renaming: FotoPerson?
    @State private var nameInput = ""
    @State private var pendingMerge: MergePlan?

    /// A pending "rename into an existing name" that will merge two people.
    private struct MergePlan: Identifiable {
        let id = UUID()
        let source: FotoPerson
        let target: FotoPerson
    }

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 150), spacing: 16)]

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("사람")
                .toolbar {
                    if model.unnamedCount > 0 {
                        ToolbarItem {
                            Toggle(isOn: Binding(get: { model.showUnnamed }, set: { model.showUnnamed = $0 })) {
                                Label("이름 없는 사람", systemImage: "person.fill.questionmark")
                            }
                            .toggleStyle(.button)
                            .help("이름이 지정되지 않은 인물 보기")
                        }
                    }
                }
                .navigationDestination(for: FotoPerson.self) { person in
                    PersonDetailView(person: person, model: model)
                }
        }
        .task { await model.loadIfNeeded() }
        .alert(renaming?.isNamed == true ? "이름 변경" : "이름 지정",
               isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
               presenting: renaming) { person in
            TextField("이름", text: $nameInput)
            Button("저장") {
                let name = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                // If another person already has this name, merge into them
                // (after a confirmation); otherwise just rename.
                if let existing = model.existingPerson(forName: name, excluding: person.id) {
                    pendingMerge = MergePlan(source: person, target: existing)
                } else {
                    Task { await model.rename(person, to: name) }
                }
                renaming = nil
            }
            Button("취소", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(
            "같은 이름의 사람과 병합",
            isPresented: Binding(get: { pendingMerge != nil }, set: { if !$0 { pendingMerge = nil } }),
            presenting: pendingMerge
        ) { plan in
            Button("병합", role: .destructive) {
                let p = plan
                Task { await model.merge(p.source, into: p.target) }
                pendingMerge = nil
            }
            Button("취소", role: .cancel) { pendingMerge = nil }
        } message: { plan in
            Text("‘\(plan.target.displayName)’(이)라는 사람이 이미 있습니다. 이 인물의 사진을 그 사람으로 합칩니다. 병합은 되돌릴 수 없습니다.")
        }
    }

    private func startRename(_ person: FotoPerson) {
        nameInput = person.name
        renaming = person
    }

    @ViewBuilder
    private var content: some View {
        if model.people.isEmpty && model.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.people.isEmpty {
            ContentUnavailableView {
                Label("인식된 사람 없음", systemImage: "person.crop.circle.badge.questionmark")
            } description: {
                Text("NAS의 Synology Photos에서 얼굴 인식이 켜져 있고 색인이 끝나야 사람이 표시됩니다.")
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(model.visiblePeople) { person in
                        NavigationLink(value: person) {
                            PersonCard(person: person, loader: model.thumbnailLoader)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(person.isNamed ? "이름 변경" : "이름 지정") { startRename(person) }
                            if person.isNamed {
                                Button("이름 지우기", role: .destructive) {
                                    Task { await model.rename(person, to: "") }
                                }
                            }
                        }
                    }
                }
                .padding()
            }
        }
    }
}

private struct PersonCard: View {
    let person: FotoPerson
    let loader: ThumbnailLoader

    @State private var cover: NSImage?

    var body: some View {
        VStack(spacing: 8) {
            Circle()
                .fill(.quaternary)
                .overlay {
                    if let cover {
                        Image(nsImage: cover).resizable().scaledToFill()
                    } else {
                        Image(systemName: "person.fill").font(.largeTitle).foregroundStyle(.secondary)
                    }
                }
                .clipShape(Circle())
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .overlay(Circle().strokeBorder(.quaternary, lineWidth: 0.5))
            Text(person.displayName)
                .font(.callout)
                .foregroundStyle(person.isNamed ? .primary : .secondary)
                .lineLimit(1)
            Text("\(person.itemCount)장").font(.caption).foregroundStyle(.secondary)
        }
        .task(id: person.id) {
            cover = await loader.image(forPerson: person)
        }
    }
}

/// A single person's photos: paginated grid with the standard selection/preview/
/// right-click behaviour, plus "대표 사진으로 설정".
struct PersonDetailView: View {
    let person: FotoPerson
    let model: PeopleViewModel

    @State private var grid: ItemGridViewModel?

    var body: some View {
        Group {
            if let grid {
                DetailGridView(
                    grid: grid,
                    extraAction: .init(title: "대표 사진으로 설정", systemImage: "person.crop.circle.badge.checkmark", allowsMultiple: false) { items in
                        guard let first = items.first else { return }
                        Task { await model.setCover(personId: person.id, photoId: first.id) }
                    }
                )
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(person.displayName)
        .navigationSubtitle("\(person.itemCount)장")
        .task(id: person.id) {
            let service = model.service
            let personId = person.id
            grid = ItemGridViewModel(loader: model.thumbnailLoader) { offset, limit in
                try await service.items(ofPerson: personId, offset: offset, limit: limit)
            }
        }
    }
}
