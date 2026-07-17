import Foundation
import Observation
import AppKit
import SynoKit
import FotoKit

// FotoSpace (personal/shared) lives in FotoKit; the app adds its display title.
extension FotoSpace {
    var title: String { self == .personal ? "개인" : "공유" }
}

/// Top-level sidebar destinations (plan §5).
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case timeline, recent, folders, albums, people, similar
    var id: String { rawValue }
    var title: String {
        switch self {
        case .timeline: return "타임라인"
        case .recent: return "최근 추가"
        case .folders: return "폴더"
        case .albums: return "앨범"
        case .people: return "사람"
        case .similar: return "유사한 항목"
        }
    }
    var systemImage: String {
        switch self {
        case .timeline: return "clock"
        case .recent: return "sparkles"
        case .folders: return "folder"
        case .albums: return "rectangle.stack"
        case .people: return "person.2"
        case .similar: return "square.on.square.dashed"
        }
    }
}

/// Connection lifecycle state, kept intentionally small for the skeleton.
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

/// A TLS trust decision the user must make (TOFU). `previousFingerprint` is
/// non-nil when a previously-trusted cert has *changed* (a stronger warning).
struct CertificateChallenge: Identifiable {
    let id = UUID()
    let host: String
    let port: Int
    let fingerprint: String
    let certData: Data
    let previousFingerprint: String?
    var isChange: Bool { previousFingerprint != nil }
}

@Observable
@MainActor
final class AppModel {
    var space: FotoSpace = .personal {
        didSet {
            fotoService?.space = space
            // Personal/shared are separate item sets — don't let one space's
            // favorite/rating overrides bleed into the other.
            clearItemOverrides()
        }
    }
    var selectedSidebarItem: SidebarItem? = .timeline
    var connectionState: ConnectionState = .disconnected

    /// Registered NAS connections (loaded from the shared credential store).
    var connections: [NASConnection] = CredentialStore.savedConnections()

    var selectedConnection: NASConnection? {
        didSet { CredentialStore.setSelectedConnectionID(selectedConnection?.id) }
    }

    /// Photos networking layer for the selected connection (nil until connected).
    var fotoService: FotoService?

    /// Whether the shared (team) space is actually usable (probed after connect).
    /// Gates the 개인/공유 toggle — the API can exist while the space is disabled.
    private(set) var sharedSpaceUsable = false

    /// Set when a connection attempt hit an untrusted/changed TLS certificate;
    /// drives the trust prompt. Cleared on accept/reject.
    var pendingCertificate: CertificateChallenge?
    private var pendingPassword: String?
    private var pendingOTP: String?

    init() {
        let selectedID = CredentialStore.selectedConnectionID()
        selectedConnection = connections.first { $0.id == selectedID } ?? connections.first
    }

    /// Logs into the selected NAS and readies `fotoService`. Read-only browsing
    /// wiring for Phase 1; the grid/timeline views consume `fotoService`.
    func connect(password: String, otpCode: String? = nil) async {
        guard let connection = selectedConnection else { return }
        connectionState = .connecting
        let service = FotoService(connection: connection, space: space)
        do {
            try await service.connect(username: connection.username, password: password, otpCode: otpCode)
            fotoService = service
            connectionState = .connected
            // Only surface the 개인/공유 toggle when the shared space really works
            // (its API can exist while disabled → err 801). Probe after connect.
            sharedSpaceUsable = await service.sharedSpaceIsUsable()
        } catch let SynologyAPIError.certificateUntrusted(host, port, fingerprint, certData) {
            awaitCertificateDecision(host: host, port: port, fingerprint: fingerprint,
                                     certData: certData, previous: nil, password: password, otpCode: otpCode)
        } catch let SynologyAPIError.certificateChanged(host, port, old, new, certData) {
            awaitCertificateDecision(host: host, port: port, fingerprint: new,
                                     certData: certData, previous: old, password: password, otpCode: otpCode)
        } catch {
            connectionState = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func awaitCertificateDecision(host: String, port: Int, fingerprint: String, certData: Data,
                                          previous: String?, password: String, otpCode: String?) {
        pendingPassword = password
        pendingOTP = otpCode
        pendingCertificate = CertificateChallenge(host: host, port: port, fingerprint: fingerprint,
                                                  certData: certData, previousFingerprint: previous)
        connectionState = .disconnected   // waiting on the user's trust decision
    }

    /// User accepted the cert: pin it (TOFU) and retry the connection.
    func trustPendingCertificate() async {
        guard let challenge = pendingCertificate else { return }
        TrustedCertificateStore.pin(certificateData: challenge.certData, for: challenge.host, port: challenge.port)
        let password = pendingPassword
        let otp = pendingOTP
        pendingCertificate = nil
        pendingPassword = nil
        pendingOTP = nil
        if let password { await connect(password: password, otpCode: otp) }
    }

    func rejectPendingCertificate() {
        pendingCertificate = nil
        pendingPassword = nil
        pendingOTP = nil
        connectionState = .failed("인증서를 신뢰하지 않아 연결이 취소되었습니다.")
    }

    // MARK: - Albums (add-to-album from selection)

    func loadAlbums() async -> [FotoAlbum] {
        (try? await fotoService?.albums()) ?? []
    }

    func addToAlbum(_ items: [FotoItem], albumId: Int) async {
        guard !items.isEmpty else { return }
        try? await fotoService?.addItems(albumId: albumId, itemIds: items.map(\.id))
    }

    /// Creates a new album containing `items`.
    func createAlbum(named name: String, with items: [FotoItem]) async {
        guard let service = fotoService else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let album = try? await service.createAlbum(name: trimmed) else { return }
        if !items.isEmpty { try? await service.addItems(albumId: album.id, itemIds: items.map(\.id)) }
    }

    // MARK: - User notices (errors + brief confirmations)

    struct Notice: Identifiable, Equatable {
        enum Kind { case error, info }
        let id = UUID()
        let kind: Kind
        let message: String
    }

    /// The one currently-shown banner. Errors persist until dismissed; info
    /// notices auto-clear after a few seconds.
    var notice: Notice?
    private var noticeClearTask: Task<Void, Never>?

    func showError(_ message: String) {
        noticeClearTask?.cancel()
        notice = Notice(kind: .error, message: message)
    }

    func showInfo(_ message: String) {
        noticeClearTask?.cancel()
        let n = Notice(kind: .info, message: message)
        notice = n
        noticeClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            if self?.notice == n { self?.notice = nil }
        }
    }

    // MARK: - Mutations (delete / upload) — bump to trigger a grid refresh

    private(set) var mutationCounter = 0
    var isUploading = false
    private(set) var uploadDone = 0
    private(set) var uploadTotal = 0

    /// Permanently deletes items. ⚠️ No app-level trash exists in Synology
    /// Photos — call only behind an explicit confirmation.
    func deleteItem(_ item: FotoItem) async { await deleteItems([item]) }

    /// Successful deletions are applied to the grids LOCALLY (via
    /// `deletedIDs`/`deletionCounter`) instead of a full reload, so the scroll
    /// position is preserved.
    private(set) var deletedIDs: Set<Int> = []
    private(set) var deletionCounter = 0

    func deleteItems(_ items: [FotoItem]) async {
        guard let service = fotoService, !items.isEmpty else { return }
        do {
            try await service.deleteItems(itemIds: items.map(\.id))
            deletedIDs = Set(items.map(\.id))
            deletionCounter += 1
            showInfo(items.count > 1 ? "\(items.count)장을 삭제했습니다." : "사진을 삭제했습니다.")
        } catch {
            showError("삭제 실패: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        }
    }

    // MARK: - Favorites (heart)

    /// Local favorite state, applied on top of the item's server value so a
    /// toggle reflects instantly across every grid without a reload. Keyed by id.
    private(set) var favoriteOverrides: [Int: Bool] = [:]
    private(set) var favoriteCounter = 0

    func isFavorite(_ item: FotoItem) -> Bool { favoriteOverrides[item.id] ?? item.isFavorite }

    /// Drops all local favorite/rating overrides (on space switch / disconnect),
    /// so freshly-loaded items show their true server state.
    func clearItemOverrides() {
        favoriteOverrides = [:]
        ratingOverrides = [:]
    }

    /// Toggles the heart for the given items. If any are not favorited, favorites
    /// all; otherwise un-favorites all (matches Photos' batch behavior).
    func toggleFavorite(_ items: [FotoItem]) async {
        guard let service = fotoService, !items.isEmpty else { return }
        let target = !items.allSatisfy { isFavorite($0) }
        do {
            try await service.setFavorite(itemIds: items.map(\.id), favorite: target)
            for item in items { favoriteOverrides[item.id] = target }
            favoriteCounter += 1
            showInfo(target ? (items.count > 1 ? "\(items.count)장을 즐겨찾기에 추가했습니다." : "즐겨찾기에 추가했습니다.")
                            : "즐겨찾기에서 제거했습니다.")
        } catch {
            showError("즐겨찾기 변경 실패: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        }
    }

    // MARK: - Rating (0–5 stars)

    /// Local rating overrides, applied on top of the item's server value for
    /// instant UI feedback. Keyed by id.
    private(set) var ratingOverrides: [Int: Int] = [:]
    private(set) var ratingCounter = 0

    func rating(_ item: FotoItem) -> Int { ratingOverrides[item.id] ?? item.rating }

    /// Sets a star rating on items. Tapping the current rating's star again
    /// clears it (rating 0), matching the usual star-control behavior.
    func setRating(_ items: [FotoItem], to rating: Int) async {
        guard let service = fotoService, !items.isEmpty else { return }
        do {
            try await service.setRating(itemIds: items.map(\.id), rating: rating)
            for item in items { ratingOverrides[item.id] = rating }
            ratingCounter += 1
        } catch {
            showError("별점 변경 실패: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        }
    }

    /// Changes an item's taken-date and refreshes the grids (the timeline
    /// re-sorts). Returns true on success.
    @discardableResult
    func editTakenDate(_ item: FotoItem, to date: Date) async -> Bool {
        guard let service = fotoService else { return false }
        do {
            try await service.setTakenTime(itemIds: [item.id], to: date)
            mutationCounter += 1
            showInfo("촬영일을 변경했습니다.")
            return true
        } catch {
            showError("촬영일 변경 실패: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            return false
        }
    }

    /// Records a deletion already performed on the server (e.g. by the similar-
    /// photos cleanup) so the timeline/folders/albums/people views drop those
    /// items locally, without re-issuing the delete.
    func registerExternalDeletion(_ ids: [Int]) {
        guard !ids.isEmpty else { return }
        deletedIDs = Set(ids)
        deletionCounter += 1
    }

    // MARK: - Menu command bus

    /// Actions issued by the main menu that must be handled by whichever center
    /// view is active. ContentView observes `menuCommandCounter` and routes
    /// `lastMenuCommand` to the active view model.
    enum MenuCommand: Equatable {
        case selectAll, deselectAll, download, delete
        case scale(TimelineScale), toggleFilter
    }
    private(set) var lastMenuCommand: MenuCommand?
    private(set) var menuCommandCounter = 0
    func sendMenuCommand(_ command: MenuCommand) {
        lastMenuCommand = command
        menuCommandCounter += 1
    }

    /// Whether the timeline-only menu items (scale, filter) apply right now.
    var isTimelineActive: Bool { selectedSidebarItem == .timeline || selectedSidebarItem == nil }
    var canOperateOnItems: Bool {
        fotoService != nil && (selectedSidebarItem == .timeline || selectedSidebarItem == .folders || selectedSidebarItem == nil)
    }

    /// Shows an open panel and uploads the chosen images to the timeline.
    func pickAndUpload() async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie]
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        await upload(panel.urls)
    }

    func upload(_ urls: [URL]) async {
        guard let service = fotoService, !isUploading else { return }
        isUploading = true
        uploadTotal = urls.count
        uploadDone = 0
        defer { isUploading = false; uploadTotal = 0; uploadDone = 0 }

        var succeeded = 0
        var failures: [String] = []
        for url in urls {
            defer { uploadDone += 1 }
            guard let data = try? Data(contentsOf: url) else {
                failures.append(url.lastPathComponent); continue
            }
            do {
                try await service.uploadItem(filename: url.lastPathComponent, data: data)
                succeeded += 1
            } catch {
                failures.append(url.lastPathComponent)
            }
        }

        if failures.isEmpty {
            showInfo("\(succeeded)개 업로드 완료")
        } else {
            let sample = failures.prefix(3).joined(separator: ", ")
            showError("업로드: \(succeeded)개 성공, \(failures.count)개 실패 (\(sample)\(failures.count > 3 ? " 외" : ""))")
        }
        if succeeded > 0 { mutationCounter += 1 }
    }

    // MARK: - Download

    var isDownloading = false

    /// Downloads an item's original and saves it to a user-chosen location
    /// (NSSavePanel — the user picks where, so this only ever writes locally).
    func downloadOriginal(_ item: FotoItem) async { await downloadItems([item]) }

    /// Downloads one item (original) or many (a zip), to a user-chosen location.
    func downloadItems(_ items: [FotoItem]) async {
        guard let service = fotoService, !isDownloading, !items.isEmpty else { return }
        // Pick the destination first (on the main actor), then stream to it.
        let panel = NSSavePanel()
        panel.nameFieldStringValue = items.count == 1 ? items[0].filename : "SynologyPhotos.zip"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isDownloading = true
        defer { isDownloading = false }
        do {
            try await service.downloadOriginal(itemIds: items.map(\.id), to: url)
            showInfo(items.count > 1 ? "\(items.count)장 다운로드 완료" : "다운로드 완료")
        } catch {
            showError("다운로드 실패: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        }
    }

    /// Adds a new NAS, saves its credential to this app's store, and connects.
    func addConnection(host: String, port: Int, username: String, password: String, otpCode: String? = nil) async {
        let connection = NASConnection(host: host, port: port, username: username)
        CredentialStore.addOrUpdate(connection: connection, password: password)
        connections = CredentialStore.savedConnections()
        selectedConnection = connection
        await connect(password: password, otpCode: otpCode)
    }

    /// On launch, silently reconnect the selected NAS if its password is stored.
    func connectSavedIfPossible() async {
        guard fotoService == nil, connectionState == .disconnected,
              let connection = selectedConnection,
              let password = CredentialStore.password(for: connection) else { return }
        await connect(password: password)
    }

    // MARK: - Settings (connection management, defaults)

    /// Tears down the current session (keeps the credential — a later launch can
    /// silently reconnect). Used by 로그아웃 and before switching NAS.
    func disconnect() {
        fotoService = nil
        connectionState = .disconnected
        sharedSpaceUsable = false
        clearItemOverrides()
    }

    /// Switches the active NAS to a stored connection and reconnects.
    func switchConnection(to connection: NASConnection) async {
        guard connection.id != selectedConnection?.id else { return }
        disconnect()
        selectedConnection = connection
        if let password = CredentialStore.password(for: connection) {
            await connect(password: password)
        } else {
            connectionState = .failed("저장된 비밀번호가 없습니다. 연결을 다시 추가하세요.")
        }
    }

    /// Removes a stored connection. If it was active, disconnects and falls back
    /// to another saved connection (or none).
    func removeConnection(_ connection: NASConnection) async {
        CredentialStore.remove(connection: connection)
        connections = CredentialStore.savedConnections()
        guard connection.id == selectedConnection?.id else { return }
        disconnect()
        selectedConnection = connections.first
        if let next = selectedConnection, let password = CredentialStore.password(for: next) {
            await connect(password: password)
        }
    }

    /// Default timeline granularity for new sessions (설정 창). Persisted.
    var defaultScale: TimelineScale {
        get { TimelineScale(rawValue: UserDefaults.standard.string(forKey: "defaultScale") ?? "") ?? .month }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "defaultScale") }
    }
}
