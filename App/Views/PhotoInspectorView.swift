import SwiftUI
import AppKit
import MapKit
import FotoKit

/// Right-pane inspector: preview + EXIF / resolution / location for the
/// selected item. Preview uses the larger `xl` thumbnail via the shared loader.
struct PhotoInspectorView: View {
    @Environment(AppModel.self) private var model
    let item: FotoItem?
    let loader: ThumbnailLoader?

    @State private var preview: NSImage?
    @State private var showingDeleteConfirm = false
    /// Full metadata (GPS/address/EXIF) fetched on selection — the grid omits it.
    @State private var detail: FotoItem?
    @State private var showingDateEdit = false
    @State private var editDate = Date()

    var body: some View {
        if let item {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.s4) {
                    previewImage

                    // Action cluster — cohesive native bordered controls.
                    HStack(spacing: DS.s2) {
                        Button {
                            Task { await model.downloadOriginal(item) }
                        } label: {
                            Label(model.isDownloading ? "다운로드 중…" : "원본 다운로드", systemImage: "arrow.down.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(model.isDownloading)

                        Button {
                            model.requestExport([item])
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .help("내보내기… (크기·형식·메타데이터)")

                        Button {
                            Task { await model.toggleFavorite([item]) }
                        } label: {
                            Image(systemName: model.isFavorite(item) ? "heart.fill" : "heart")
                                .foregroundStyle(model.isFavorite(item) ? .red : .secondary)
                                .symbolEffect(.bounce, value: model.isFavorite(item))
                        }
                        .help(model.isFavorite(item) ? "즐겨찾기 해제" : "즐겨찾기")

                        AddToAlbumMenu(items: [item])
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    // Rating + metadata, grouped on one distinct surface.
                    VStack(alignment: .leading, spacing: DS.s3) {
                        StarRatingView(item: item)
                        Divider()
                        metadata(for: detail ?? item)
                    }
                    .dsCard()

                    locationMap(for: detail ?? item)

                    Button(role: .destructive) {
                        showingDeleteConfirm = true
                    } label: {
                        Label("삭제", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(.red)
                    .confirmationDialog(
                        "이 사진을 삭제하시겠습니까?",
                        isPresented: $showingDeleteConfirm, titleVisibility: .visible
                    ) {
                        Button("삭제", role: .destructive) { Task { await model.deleteItem(item) } }
                        Button("취소", role: .cancel) {}
                    } message: {
                        Text("Synology Photos에는 휴지통이 없어 복구할 수 없습니다.")
                    }
                }
                .padding(DS.s4)
            }
            .task(id: item.id) {
                preview = nil
                detail = nil
                preview = await loader?.image(for: item, size: .xl)
                detail = try? await model.fotoService?.itemDetail(id: item.id)
            }
        } else {
            ContentUnavailableView("정보 없음", systemImage: "info.circle",
                                   description: Text("사진을 선택하면 정보가 표시됩니다."))
        }
    }

    private var previewImage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.rCard, style: .continuous).fill(.quaternary)
            if let preview {
                Image(nsImage: preview).resizable().scaledToFit()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: DS.rCard, style: .continuous))
    }

    /// The 촬영 row with an inline edit button → a date/time picker popover.
    @ViewBuilder
    private func takenRow(for item: FotoItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("촬영").font(.caption).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            Text(item.takenAt.formatted(date: .abbreviated, time: .shortened))
                .font(.callout).textSelection(.enabled)
            Spacer()
            Button {
                editDate = item.takenAt
                showingDateEdit = true
            } label: {
                Image(systemName: "pencil").font(.caption)
            }
            .buttonStyle(.borderless)
            .help("촬영일 수정")
            .popover(isPresented: $showingDateEdit, arrowEdge: .leading) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("촬영일 수정").font(.headline)
                    DatePicker("", selection: $editDate, displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.field)
                        .labelsHidden()
                    HStack {
                        Spacer()
                        Button("취소") { showingDateEdit = false }
                        Button("저장") {
                            showingDateEdit = false
                            Task {
                                if await model.editTakenDate(item, to: editDate) {
                                    detail = try? await model.fotoService?.itemDetail(id: item.id)
                                }
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(16)
                .frame(width: 300)
            }
        }
    }

    @ViewBuilder
    private func metadata(for item: FotoItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            row("이름", item.filename)
            row("종류", item.type == .video ? "동영상" : "사진")
            if let r = item.additional?.resolution { row("해상도", "\(r.width) × \(r.height)") }
            row("크기", ByteCountFormatter.string(fromByteCount: Int64(item.filesize), countStyle: .file))
            takenRow(for: item)

            if let exif = item.additional?.exif {
                Divider()
                if let camera = exif.camera { row("카메라", camera) }
                if let lens = exif.lens { row("렌즈", lens) }
                let settings = [exif.aperture, exif.exposureTime, exif.iso.map { "ISO \($0)" }, exif.focalLength]
                    .compactMap { $0 }.joined(separator: " · ")
                if !settings.isEmpty { row("설정", settings) }
            }

            if let addr = item.additional?.address, !addr.displayLine.isEmpty {
                Divider(); row("위치", addr.displayLine)
            }
            if let gps = item.additional?.gps {
                row("좌표", String(format: "%.5f, %.5f", gps.latitude, gps.longitude))
            }
        }
    }

    /// A mini-map with a pin at the photo's location (when it has GPS).
    @ViewBuilder
    private func locationMap(for item: FotoItem) -> some View {
        if let gps = item.additional?.gps {
            let coord = CLLocationCoordinate2D(latitude: gps.latitude, longitude: gps.longitude)
            Map(initialPosition: .region(MKCoordinateRegion(
                center: coord,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ))) {
                Marker(item.additional?.address?.displayLine ?? "촬영 위치", coordinate: coord)
            }
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: DS.rCard, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.rCard, style: .continuous).strokeBorder(DS.hairline, lineWidth: 1))
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

/// A 0–5 star rating control. Clicking a star sets that rating; clicking the
/// current highest star again clears it. Reflects `AppModel`'s local override
/// so it updates instantly.
struct StarRatingView: View {
    @Environment(AppModel.self) private var model
    let item: FotoItem

    var body: some View {
        let current = model.rating(item)
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= current ? "star.fill" : "star")
                    .foregroundStyle(star <= current ? .yellow : .secondary)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let target = (star == current) ? 0 : star   // re-tap clears
                        Task { await model.setRating([item], to: target) }
                    }
            }
            if current > 0 {
                Button {
                    Task { await model.setRating([item], to: 0) }
                } label: {
                    Image(systemName: "xmark.circle").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("별점 지우기")
            }
            Spacer()
        }
        .font(.title3)
    }
}

/// "앨범에 추가" menu — loads albums on open, adds the item(s), or creates a new
/// album. Works for a single inspector item or a multi-selection context menu.
struct AddToAlbumMenu: View {
    @Environment(AppModel.self) private var model
    let items: [FotoItem]

    @State private var albums: [FotoAlbum] = []
    @State private var showingCreate = false
    @State private var newName = ""

    var body: some View {
        Menu {
            Button("새 앨범에 추가…") { showingCreate = true }
            if !albums.isEmpty { Divider() }
            ForEach(albums) { album in
                Button(album.name) { Task { await model.addToAlbum(items, albumId: album.id) } }
            }
        } label: {
            Label("앨범에 추가", systemImage: "rectangle.stack.badge.plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .task { albums = await model.loadAlbums() }
        .alert("새 앨범", isPresented: $showingCreate) {
            TextField("앨범 이름", text: $newName)
            Button("만들기") { let n = newName; newName = ""; Task { await model.createAlbum(named: n, with: items) } }
            Button("취소", role: .cancel) { newName = "" }
        }
    }
}
