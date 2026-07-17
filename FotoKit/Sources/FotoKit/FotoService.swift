import Foundation
import SynoKit

/// Talks to one NAS's Synology Photos APIs, on top of the generic
/// `SynoKit.SynologyClient`. Switches between the personal (`SYNO.Foto.*`) and
/// shared (`SYNO.FotoTeam.*`) spaces. Networking layer only — ViewModels own
/// the observable UI state (per the plan's layering).
///
/// `@unchecked Sendable`: wraps the already-`@unchecked Sendable` SynoKit client
/// and is driven from the main actor; `space` is only mutated there.
public final class FotoService: @unchecked Sendable {
    private let client: SynologyClient
    public var space: FotoSpace

    /// Additional fields worth requesting for a browsing grid + inspector.
    /// (Deliberately excludes `person` — invalid for Browse.Item, see FINDINGS.)
    public static let gridAdditional = ["thumbnail", "resolution", "orientation", "video_meta", "favorite", "rating"]
    public static let fullAdditional = ["thumbnail", "resolution", "orientation", "exif", "gps", "address", "video_meta", "favorite", "rating"]

    private static let discoverAPIs = [
        "SYNO.API.Auth",
        "SYNO.Foto.Browse.Item", "SYNO.Foto.Browse.Timeline",
        "SYNO.Foto.Browse.Album", "SYNO.Foto.Browse.Folder",
        "SYNO.FotoTeam.Browse.Item", "SYNO.FotoTeam.Browse.Timeline",
        "SYNO.FotoTeam.Browse.Album", "SYNO.FotoTeam.Browse.Folder",
        "SYNO.Foto.Browse.NormalAlbum", "SYNO.FotoTeam.Browse.NormalAlbum",
        "SYNO.Foto.Browse.Person", "SYNO.FotoTeam.Browse.Person",
        "SYNO.Foto.Search.Search", "SYNO.FotoTeam.Search.Search",
        "SYNO.Foto.Search.Filter", "SYNO.FotoTeam.Search.Filter",
        "SYNO.Foto.Browse.SimilarItem", "SYNO.FotoTeam.Browse.SimilarItem",
        "SYNO.Foto.Browse.RecentlyAdded", "SYNO.FotoTeam.Browse.RecentlyAdded",
        "SYNO.Foto.UserInfo", "SYNO.Foto.Index",
        "SYNO.Foto.Sharing.Passphrase", "SYNO.FotoTeam.Sharing.Passphrase",
        "SYNO.Foto.Sharing.Misc", "SYNO.FotoTeam.Sharing.Misc",
        "SYNO.Foto.Upload.Item", "SYNO.FotoTeam.Upload.Item",
        "SYNO.Foto.Thumbnail", "SYNO.Foto.Download",
    ]
    // All PERSONAL-space APIs the app depends on are required, so if the NAS's
    // targeted discovery query silently drops any (it does when the list is long),
    // the `query=all` sweep resolves them. FotoTeam (shared) APIs stay optional —
    // on NASes where the shared space isn't set up they don't discover, and the
    // ViewModels clear on the resulting error rather than showing stale data.
    private static let requiredAPIs: Set<String> = [
        "SYNO.API.Auth",
        "SYNO.Foto.Browse.Item", "SYNO.Foto.Browse.Timeline", "SYNO.Foto.Browse.Album",
        "SYNO.Foto.Browse.Folder", "SYNO.Foto.Browse.NormalAlbum", "SYNO.Foto.Browse.Person",
        "SYNO.Foto.Browse.SimilarItem", "SYNO.Foto.Search.Search", "SYNO.Foto.Search.Filter",
        "SYNO.Foto.Upload.Item", "SYNO.Foto.Thumbnail", "SYNO.Foto.Download",
    ]

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    public init(connection: NASConnection, space: FotoSpace = .personal) {
        self.client = SynologyClient(connection: connection, sessionName: "SynologyPhotosManager")
        self.space = space
    }

    /// Test seam: inject a stubbed client.
    public init(client: SynologyClient, space: FotoSpace = .personal) {
        self.client = client
        self.space = space
    }

    public var isAuthenticated: Bool { client.isAuthenticated }

    /// Whether the shared (team)-space API endpoint is even discovered. NOTE:
    /// discovery is NOT enough — the endpoint can exist while the space is
    /// disabled for this user (querying it then returns err 801). Use
    /// `sharedSpaceIsUsable()` to gate UI.
    public var sharedSpaceAvailable: Bool {
        client.endpoint(for: "SYNO.FotoTeam.Browse.Item") != nil
    }

    /// Actually probes the shared (team) space — a lightweight `count` — so the
    /// 개인/공유 toggle only appears when switching there will really work.
    /// Returns false when the space is disabled (err 801) or absent.
    public func sharedSpaceIsUsable() async -> Bool {
        guard sharedSpaceAvailable else { return false }
        do {
            _ = try await decoded(FotoCountData.self, api: "SYNO.FotoTeam.Browse.Item", method: "count")
            return true
        } catch {
            return false
        }
    }

    // MARK: - Session

    public func connect(username: String, password: String, otpCode: String? = nil) async throws {
        // Not force-refreshed: the cache key now includes `required`, so the
        // expanded required set (below) busts any stale map that dropped an API,
        // and the required-triggered `query=all` sweep resolves everything on the
        // next discovery — then it's cached normally.
        try await client.discoverAPIs(Self.discoverAPIs, required: Self.requiredAPIs)
        try await client.login(username: username, password: password, otpCode: otpCode)
    }

    public func disconnect() async { try? await client.logout() }

    // MARK: - Browse

    public func timeline() async throws -> [FotoTimelineSection] {
        try await decoded(FotoTimelineData.self, api: browse("Timeline"), method: "get").section
    }

    public func items(offset: Int, limit: Int, additional: [String] = FotoService.gridAdditional) async throws -> [FotoItem] {
        try await decoded(FotoItemListData.self, api: browse("Item"), method: "list", query: [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort_by", value: "takentime"),
            URLQueryItem(name: "sort_direction", value: "desc"),
            URLQueryItem(name: "additional", value: additionalParam(additional)),
        ]).list
    }

    /// Full metadata (GPS / address / EXIF) for a single item — the browsing grid
    /// omits these for payload size. ⚠️ Uses `get` with the id in **array** form
    /// (`id=[<id>]`); the non-array form returns an empty `additional`.
    public func itemDetail(id: Int, additional: [String] = FotoService.fullAdditional) async throws -> FotoItem? {
        try await decoded(FotoItemListData.self, api: browse("Item"), method: "get", query: [
            URLQueryItem(name: "id", value: "[\(id)]"),
            URLQueryItem(name: "additional", value: additionalParam(additional)),
        ]).list.first
    }

    public func itemCount() async throws -> Int {
        try await decoded(FotoCountData.self, api: browse("Item"), method: "count").count
    }

    /// Items directly inside a folder (not recursive), sorted by filename.
    public func items(inFolder folderId: Int, offset: Int, limit: Int, additional: [String] = FotoService.gridAdditional) async throws -> [FotoItem] {
        try await decoded(FotoItemListData.self, api: browse("Item"), method: "list", query: [
            URLQueryItem(name: "folder_id", value: String(folderId)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort_by", value: "filename"),
            URLQueryItem(name: "sort_direction", value: "asc"),
            URLQueryItem(name: "additional", value: additionalParam(additional)),
        ]).list
    }

    public func itemCount(inFolder folderId: Int) async throws -> Int {
        try await decoded(FotoCountData.self, api: browse("Item"), method: "count", query: [
            URLQueryItem(name: "folder_id", value: String(folderId)),
        ]).count
    }

    public func folders(parentId: Int) async throws -> [FotoFolder] {
        try await decoded(FotoFolderListData.self, api: browse("Folder"), method: "list", query: [
            URLQueryItem(name: "id", value: String(parentId)),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: "1000"),
        ]).list
    }

    public func rootFolder() async throws -> FotoFolder {
        try await decoded(FotoFolderData.self, api: browse("Folder"), method: "get", query: [
            URLQueryItem(name: "id", value: "0"),
        ]).folder
    }

    // MARK: - Albums

    public func albums(offset: Int = 0, limit: Int = 500) async throws -> [FotoAlbum] {
        try await decoded(FotoAlbumListData.self, api: browse("Album"), method: "list", query: [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort_by", value: "create_time"),
            URLQueryItem(name: "sort_direction", value: "desc"),
            URLQueryItem(name: "additional", value: "[\"thumbnail\"]"),
        ]).list
    }

    public func items(inAlbum albumId: Int, offset: Int, limit: Int, additional: [String] = FotoService.gridAdditional) async throws -> [FotoItem] {
        try await decoded(FotoItemListData.self, api: browse("Item"), method: "list", query: [
            URLQueryItem(name: "album_id", value: String(albumId)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "additional", value: additionalParam(additional)),
        ]).list
    }

    @discardableResult
    public func createAlbum(name: String) async throws -> FotoAlbum {
        try await decoded(FotoAlbumCreateData.self, api: normalAlbum(), method: "create", query: [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "item", value: "[]"),
        ]).album
    }

    /// Sets the star rating (0–5) on items. `SYNO.Foto.Browse.Item set {id, rating}`
    /// — verified live on a REAL indexed photo (round-trip + restore). Note:
    /// freshly-uploaded/un-indexed items silently ignore rating (return success
    /// but the value stays 0), so this only "sticks" once a photo is indexed.
    public func setRating(itemIds: [Int], rating: Int) async throws {
        guard !itemIds.isEmpty else { return }
        try await client.performSuccess(api: browse("Item"), method: "set", queryItems: [
            URLQueryItem(name: "id", value: idArray(itemIds)),
            URLQueryItem(name: "rating", value: String(max(0, min(5, rating)))),
        ])
    }

    /// Hearts / un-hearts items. `SYNO.Foto.Browse.Item set_favorite {id, favorite}`
    /// — verified live (round-trip: set → favorite surfaces in the item list).
    public func setFavorite(itemIds: [Int], favorite: Bool) async throws {
        guard !itemIds.isEmpty else { return }
        try await client.performSuccess(api: browse("Item"), method: "set_favorite", queryItems: [
            URLQueryItem(name: "id", value: idArray(itemIds)),
            URLQueryItem(name: "favorite", value: favorite ? "true" : "false"),
        ])
    }

    /// The signed-in user (`SYNO.Foto.UserInfo me`). Space-independent.
    public func userInfo() async throws -> FotoUserInfo {
        try await decoded(FotoUserInfo.self, api: "SYNO.Foto.UserInfo", method: "me")
    }

    /// Indexing progress (`SYNO.Foto.Index get`). Space-independent.
    public func indexStatus() async throws -> FotoIndexStatus {
        try await decoded(FotoIndexStatus.self, api: "SYNO.Foto.Index", method: "get")
    }

    /// Recently-added items (newest first). `SYNO.Foto.Browse.RecentlyAdded list`.
    public func recentlyAdded(offset: Int, limit: Int, additional: [String] = FotoService.gridAdditional) async throws -> [FotoItem] {
        let api = space == .personal ? "SYNO.Foto.Browse.RecentlyAdded" : "SYNO.FotoTeam.Browse.RecentlyAdded"
        return try await decoded(FotoItemListData.self, api: api, method: "list", query: [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "additional", value: additionalParam(additional)),
        ]).list
    }

    /// Changes the taken-date of one or more items. `SYNO.Foto.Browse.Item set`
    /// with `id=[...]` and `time` in **unix seconds** — verified live on a test
    /// upload. Re-sorts the timeline, so callers should refresh afterwards.
    public func setTakenTime(itemIds: [Int], to date: Date) async throws {
        guard !itemIds.isEmpty else { return }
        try await client.performSuccess(api: browse("Item"), method: "set", queryItems: [
            URLQueryItem(name: "id", value: idArray(itemIds)),
            URLQueryItem(name: "time", value: String(Int(date.timeIntervalSince1970))),
        ])
    }

    /// Renames an album. Method `set_name` on `Browse.Album` (NOT NormalAlbum),
    /// name JSON-encoded — verified live on a test album.
    public func renameAlbum(id: Int, name: String) async throws {
        try await client.performSuccess(api: browse("Album"), method: "set_name", queryItems: [
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "name", value: jsonString(name)),
        ])
    }

    public func deleteAlbums(ids: [Int]) async throws {
        try await client.performSuccess(api: browse("Album"), method: "delete", queryItems: [
            URLQueryItem(name: "id", value: idArray(ids)),
        ])
    }

    public func addItems(albumId: Int, itemIds: [Int]) async throws {
        try await client.performSuccess(api: normalAlbum(), method: "add_item", queryItems: [
            URLQueryItem(name: "id", value: String(albumId)),
            URLQueryItem(name: "item", value: idArray(itemIds)),
        ])
    }

    public func removeItems(albumId: Int, itemIds: [Int]) async throws {
        try await client.performSuccess(api: normalAlbum(), method: "delete_item", queryItems: [
            URLQueryItem(name: "id", value: String(albumId)),
            URLQueryItem(name: "item", value: idArray(itemIds)),
        ])
    }

    private func normalAlbum() -> String {
        space == .personal ? "SYNO.Foto.Browse.NormalAlbum" : "SYNO.FotoTeam.Browse.NormalAlbum"
    }

    private func idArray(_ ids: [Int]) -> String {
        "[" + ids.map(String.init).joined(separator: ",") + "]"
    }

    // MARK: - Search

    /// Full-text search over the library (filenames, people, places, tags…).
    /// `SYNO.Foto.Search.Search list_item` returns the same item schema as
    /// Browse.Item, so results decode straight into `FotoItem`.
    public func search(keyword: String, offset: Int = 0, limit: Int = 300, additional: [String] = FotoService.gridAdditional) async throws -> [FotoItem] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await decoded(FotoItemListData.self, api: searchAPI(), method: "list_item", query: [
            URLQueryItem(name: "keyword", value: trimmed),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "additional", value: additionalParam(additional)),
        ]).list
    }

    /// Browses the library with structured filters (no keyword). Backed by
    /// `SYNO.Foto.Browse.SimilarItem list_with_filter` (v2, params captured from
    /// the web). `itemTypes`: 0=photo, 1=video (e.g. `[1]` for videos, `[0,1]` for
    /// all). `timeRanges`: unix-second [(start,end)] windows (empty = all time).
    public func filteredItems(itemTypes: [Int], timeRanges: [(start: Int, end: Int)] = [],
                              personIds: [Int] = [], personPolicy: String = "or",
                              geocodingIds: [Int] = [], favoriteOnly: Bool = false,
                              cameraIds: [Int] = [], lensIds: [Int] = [], isoIds: [Int] = [], apertureIds: [Int] = [],
                              offset: Int, limit: Int, additional: [String] = FotoService.gridAdditional) async throws -> [FotoItem] {
        var query = [
            URLQueryItem(name: "item_type", value: "[" + itemTypes.map(String.init).joined(separator: ",") + "]"),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "additional", value: additionalParam(additional)),
        ]
        // Favorites-only: `favorite=true` on the filtered browse — verified live
        // (returns exactly the hearted items).
        if favoriteOnly { query.append(URLQueryItem(name: "favorite", value: "true")) }
        if !timeRanges.isEmpty {
            let json = "[" + timeRanges.map { "{\"start_time\":\($0.start),\"end_time\":\($0.end)}" }.joined(separator: ",") + "]"
            query.append(URLQueryItem(name: "time", value: json))
        }
        // Person filter: `person=[ids]` + `person_policy` ("or" = any, "and" = all).
        if !personIds.isEmpty {
            query.append(URLQueryItem(name: "person", value: "[" + personIds.map(String.init).joined(separator: ",") + "]"))
            query.append(URLQueryItem(name: "person_policy", value: personPolicy))
        }
        // Place + EXIF filters — each an id list against its facet.
        for (name, ids): (String, [Int]) in [
            ("geocoding", geocodingIds), ("camera", cameraIds),
            ("lens", lensIds), ("iso", isoIds), ("aperture", apertureIds),
        ] where !ids.isEmpty {
            query.append(URLQueryItem(name: name, value: "[" + ids.map(String.init).joined(separator: ",") + "]"))
        }
        let api = space == .personal ? "SYNO.Foto.Browse.SimilarItem" : "SYNO.FotoTeam.Browse.SimilarItem"
        return try await decoded(FotoItemListData.self, api: api, method: "list_with_filter", version: 2, query: query).list
    }

    /// Available filter-facet values (camera / lens / ISO / aperture / place tree)
    /// from `SYNO.Foto.Search.Filter list_in_similar`. The ids feed `filteredItems`.
    public func filterFacets() async throws -> FotoFilterFacets {
        let setting = "{\"focal_length_group\":false,\"general_tag\":false,\"iso\":true,\"exposure_time_group\":false,\"camera\":true,\"item_type\":false,\"time\":false,\"aperture\":true,\"flash\":false,\"person\":false,\"geocoding\":true,\"favorite\":false,\"rating\":false,\"lens\":true}"
        let api = space == .personal ? "SYNO.Foto.Search.Filter" : "SYNO.FotoTeam.Search.Filter"
        return try await decoded(FotoFilterFacets.self, api: api, method: "list_in_similar", version: 4, query: [
            URLQueryItem(name: "setting", value: setting),
            URLQueryItem(name: "additional", value: "[\"thumbnail\"]"),
        ])
    }

    /// Autocomplete suggestions (people / places / tags) for a partial keyword.
    public func suggestions(for keyword: String) async throws -> [FotoSearchSuggestion] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await decoded(FotoSuggestListData.self, api: searchAPI(), method: "suggest", query: [
            URLQueryItem(name: "keyword", value: trimmed),
        ]).list
    }

    private func searchAPI() -> String {
        space == .personal ? "SYNO.Foto.Search.Search" : "SYNO.FotoTeam.Search.Search"
    }

    // MARK: - People (face recognition)

    /// Recognized people (face clusters), ordered by photo count as DSM returns
    /// them. Named clusters carry `name`; unnamed ones have an empty string.
    /// Requires face recognition to be enabled + indexed on the NAS.
    /// ⚠️ `show_more=true` is required to get the FULL set — without it DSM
    /// returns only the larger clusters (verified: 47 without vs 114 with), which
    /// hides smaller/newer people the web shows.
    public func persons(offset: Int = 0, limit: Int = 1000) async throws -> [FotoPerson] {
        try await decoded(FotoPersonListData.self, api: browse("Person"), method: "list", query: [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "additional", value: "[\"thumbnail\"]"),
            URLQueryItem(name: "show_more", value: "true"),
        ]).list
    }

    /// Photos of one recognized person, newest first. ⚠️ The filter key is
    /// **`person_id`** (single value) — verified live: `person=` is silently
    /// IGNORED (returns the unfiltered timeline), while `person_id=2` returns
    /// exactly that person's 61 photos.
    public func items(ofPerson personId: Int, offset: Int, limit: Int, additional: [String] = FotoService.gridAdditional) async throws -> [FotoItem] {
        try await decoded(FotoItemListData.self, api: browse("Item"), method: "list", query: [
            URLQueryItem(name: "person_id", value: String(personId)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort_by", value: "takentime"),
            URLQueryItem(name: "sort_direction", value: "desc"),
            URLQueryItem(name: "additional", value: additionalParam(additional)),
        ]).list
    }

    /// Names (or renames) a recognized person. Method `set` on `Browse.Person`;
    /// the `name` value is **JSON-encoded** (verified live: a plain empty value
    /// → err 120, but `""` clears it, and `"홍길동"` stores unquoted). An empty
    /// string clears the name (cluster becomes "unnamed").
    public func renamePerson(id: Int, name: String) async throws {
        try await client.performSuccess(api: browse("Person"), method: "set", queryItems: [
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "name", value: jsonString(name)),
        ])
    }

    /// Merges the `mergedIds` face clusters INTO `targetId` (the survivor),
    /// naming the result `name`. Method `merge` (version 2), params captured from
    /// the DSM web client. ⚠️ IRREVERSIBLE — permanently combines the clusters.
    public func mergePersons(targetId: Int, mergedIds: [Int], name: String) async throws {
        try await client.performSuccess(api: browse("Person"), method: "merge", version: 2, queryItems: [
            URLQueryItem(name: "target_id", value: String(targetId)),
            URLQueryItem(name: "merged_id", value: idArray(mergedIds)),
            URLQueryItem(name: "name", value: jsonString(name)),
        ])
    }

    /// Sets a person's cover (representative) photo. Method `set_cover` on
    /// `Browse.Person` with `id`=person and **`photo_id`**=a photo item id (the
    /// server picks that person's face within it). Params captured from the DSM
    /// web client. Pass a photo the person actually appears in.
    public func setPersonCover(personId: Int, photoId: Int) async throws {
        try await client.performSuccess(api: browse("Person"), method: "set_cover", queryItems: [
            URLQueryItem(name: "id", value: String(personId)),
            URLQueryItem(name: "photo_id", value: String(photoId)),
        ])
    }

    /// A person's tight face-crop thumbnail (`type=person`). ⚠️ The `id` is the
    /// **person's id** (`FotoPerson.id`), NOT the `cover` field — verified live:
    /// `id=<cover>` returns a generic grey-silhouette placeholder, while
    /// `id=<personId>` returns the real crop for every person (matches the web
    /// People view). `cacheKey` comes from `additional.thumbnail`.
    public func personFaceCropData(personId: Int, cacheKey: String, size: FotoThumbnail.Size = .sm) async throws -> Data {
        try await client.requestData(api: "SYNO.Foto.Thumbnail", method: "get", queryItems: [
            URLQueryItem(name: "id", value: String(personId)),
            URLQueryItem(name: "cache_key", value: cacheKey),
            URLQueryItem(name: "type", value: "person"),
            URLQueryItem(name: "size", value: size.rawValue),
        ])
    }

    // MARK: - Sharing (public links)
    //
    // Synology models a share as a "shared album": creating a NormalAlbum with
    // `shared=true` mints a passphrase; `Sharing.Passphrase update` toggles the
    // public-view permission; the album's `sharing_info` carries the ready
    // `sharing_link`. All verified live.

    private func sharingPassphrase() -> String {
        space == .personal ? "SYNO.Foto.Sharing.Passphrase" : "SYNO.FotoTeam.Sharing.Passphrase"
    }

    /// Creates a public share link for `itemIds` (as a new shared album) and
    /// returns the share + the shared album's id (for later disable/read).
    public func createShareLink(name: String, itemIds: [Int]) async throws -> (share: FotoShare, albumId: Int) {
        let album = try await decoded(FotoAlbumCreateData.self, api: normalAlbum(), method: "create", query: [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "item", value: idArray(itemIds)),
            URLQueryItem(name: "shared", value: "true"),
        ]).album
        guard let passphrase = album.passphrase, !passphrase.isEmpty else { throw FotoError.server(code: -1) }
        try await setSharePublic(passphrase: passphrase, enabled: true)
        let share = try await shareInfo(albumId: album.id)
            ?? FotoShare(passphrase: passphrase, sharingLink: nil, privacyType: "public-view", enablePassword: nil, expiration: 0)
        return (share, album.id)
    }

    /// Enables/disables the public-view permission on a share passphrase.
    public func setSharePublic(passphrase: String, enabled: Bool) async throws {
        let action = enabled ? "update" : "delete"
        try await client.performSuccess(api: sharingPassphrase(), method: "update", queryItems: [
            URLQueryItem(name: "passphrase", value: jsonString(passphrase)),
            URLQueryItem(name: "expiration", value: "0"),
            URLQueryItem(name: "permission", value: "[{\"action\":\"\(action)\",\"role\":\"view\",\"member\":{\"type\":\"public\"}}]"),
        ])
    }

    /// Reads an album's current share state from its `sharing_info`.
    public func shareInfo(albumId: Int) async throws -> FotoShare? {
        try await decoded(FotoAlbumGetData.self, api: browse("Album"), method: "get", query: [
            URLQueryItem(name: "id", value: "[\(albumId)]"),
            URLQueryItem(name: "additional", value: "[\"sharing_info\"]"),
        ]).list.first?.additional?.sharingInfo
    }

    // MARK: - Download (space-independent)

    /// Downloads original file bytes. One id → the original file; multiple ids →
    /// a ZIP archive (verified against DSM). Large payloads — call off the main
    /// actor's critical path.
    public func originalData(itemIds: [Int]) async throws -> Data {
        let joined = itemIds.map(String.init).joined(separator: ",")
        return try await client.requestData(api: "SYNO.Foto.Download", method: "download", queryItems: [
            URLQueryItem(name: "unit_id", value: "[\(joined)]"),
        ])
    }

    /// Whether a batch download (2+ items) returns a zip rather than a raw file.
    public static func isBatch(_ itemIds: [Int]) -> Bool { itemIds.count > 1 }

    /// Authenticated URL of a single item's original — for AVFoundation
    /// progressive video streaming (the download endpoint supports HTTP Range,
    /// verified). nil if not connected. Load it via `rawData(for:)` so the NAS's
    /// pinned self-signed cert is trusted (AVPlayer can't do that itself).
    public func videoStreamURL(itemId: Int) -> URL? {
        client.authenticatedURL(api: "SYNO.Foto.Download", method: "download", queryItems: [
            URLQueryItem(name: "unit_id", value: "[\(itemId)]"),
        ])
    }

    /// Runs a raw (e.g. byte-range) request on the pinned session, returning the
    /// bytes + HTTP response. Backs the video streaming resource loader.
    public func rawData(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await client.rawData(for: request)
    }

    /// Streams the original(s) straight to `destination` (no memory buffering).
    /// One id → the file; many → a zip.
    public func downloadOriginal(itemIds: [Int], to destination: URL) async throws {
        let joined = itemIds.map(String.init).joined(separator: ",")
        try await client.downloadToFile(api: "SYNO.Foto.Download", method: "download", queryItems: [
            URLQueryItem(name: "unit_id", value: "[\(joined)]"),
        ], to: destination)
    }

    // MARK: - Upload / Delete (verified formats from Phase-0)

    /// Uploads a file to the personal-space timeline. Returns the new item id.
    /// Format (from the captured web request): POST to
    /// entry.cgi/SYNO.Foto.Upload.Item, api/method/version in query, and
    /// **JSON-encoded** multipart form fields (strings quoted, folder an array).
    @discardableResult
    public func uploadItem(filename: String, data: Data, mtime: Date = Date()) async throws -> Int {
        let uploadAPI = space == .personal ? "SYNO.Foto.Upload.Item" : "SYNO.FotoTeam.Upload.Item"
        let version = client.endpoint(for: uploadAPI)?.maxVersion ?? 8
        let mtimeValue = String(Int(mtime.timeIntervalSince1970))
        let nameJSON = jsonString(filename)

        let respData = try await client.requestMultipart(
            api: uploadAPI,
            extraQuery: [
                URLQueryItem(name: "api", value: uploadAPI),
                URLQueryItem(name: "method", value: "upload"),
                URLQueryItem(name: "version", value: String(version)),
            ],
            pathSuffix: uploadAPI
        ) { _, _ in
            let boundary = "----FotoKit\(UUID().uuidString)"
            var body = Data()
            func field(_ name: String, _ value: String) {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
                body.append("\(value)\r\n".data(using: .utf8)!)
            }
            field("api", uploadAPI)
            field("method", "upload")
            field("version", String(version))
            field("uploadDestination", "\"timeline\"")
            field("duplicate", "\"ignore\"")
            field("name", nameJSON)
            field("mtime", mtimeValue)
            field("folder", "[\"PhotoLibrary\"]")
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\(nameJSON)\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
            return ("multipart/form-data; boundary=\(boundary)", body)
        }

        let envelope: DSMEnvelope<FotoUploadData>
        do { envelope = try decoder.decode(DSMEnvelope<FotoUploadData>.self, from: respData) }
        catch { throw SynologyAPIError.decodingError(error) }
        guard envelope.success, let payload = envelope.data else {
            throw FotoError.from(envelope.error?.code ?? -1)
        }
        return payload.id
    }

    /// Permanently deletes items. ⚠️ Synology Photos has NO app-level trash
    /// (verified: no RecycleBin API) — recovery depends solely on the NAS
    /// shared-folder Recycle Bin setting. Treat as irreversible in the UI.
    public func deleteItems(itemIds: [Int]) async throws {
        guard !itemIds.isEmpty else { return }
        try await client.performSuccess(api: browse("Item"), method: "delete", queryItems: [
            URLQueryItem(name: "id", value: idArray(itemIds)),
        ])
    }

    private func jsonString(_ value: String) -> String {
        (try? String(data: JSONEncoder().encode(value), encoding: .utf8)) ?? "\"\(value)\""
    }

    // MARK: - Similar photos (Synology's 유사한 항목 grouping — burst / near-dupes)

    /// One page of the similar-photos browse. The list is the COLLAPSED timeline:
    /// only each group's representative row is returned (carrying `.similar` with
    /// the full member roster + `topPick`), interleaved with ungrouped photos.
    /// Group members other than the representative are NOT in this list — resolve
    /// them with `items(ids:)`. (`SYNO.Foto.Browse.SimilarItem list`, v2.)
    public func similarPage(offset: Int, limit: Int) async throws -> [FotoItem] {
        let api = space == .personal ? "SYNO.Foto.Browse.SimilarItem" : "SYNO.FotoTeam.Browse.SimilarItem"
        return try await decoded(FotoItemListData.self, api: api, method: "list", version: 2, query: [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort_by", value: "takentime"),
            URLQueryItem(name: "sort_direction", value: "desc"),
            URLQueryItem(name: "additional", value: additionalParam(FotoService.gridAdditional)),
        ]).list
    }

    /// Resolves specific items by id (batch `get id=[...]`), e.g. the members of a
    /// similar group that the collapsed `similarPage` list omits. Carries
    /// thumbnails so the group can be rendered for review.
    public func items(ids: [Int], additional: [String] = FotoService.gridAdditional) async throws -> [FotoItem] {
        guard !ids.isEmpty else { return [] }
        return try await decoded(FotoItemListData.self, api: browse("Item"), method: "get", query: [
            URLQueryItem(name: "id", value: idArray(ids)),
            URLQueryItem(name: "additional", value: additionalParam(additional)),
        ]).list
    }

    // MARK: - Thumbnails (space-independent: keyed by global unit id)

    public func thumbnailData(unitId: Int, cacheKey: String, size: FotoThumbnail.Size) async throws -> Data {
        try await client.requestData(api: "SYNO.Foto.Thumbnail", method: "get", queryItems: [
            URLQueryItem(name: "id", value: String(unitId)),
            URLQueryItem(name: "cache_key", value: cacheKey),
            URLQueryItem(name: "type", value: "unit"),
            URLQueryItem(name: "size", value: size.rawValue),
        ])
    }

    public func thumbnailData(for item: FotoItem, size: FotoThumbnail.Size) async throws -> Data {
        guard let thumb = item.additional?.thumbnail else { throw FotoError.invalidParameter }
        return try await thumbnailData(unitId: thumb.unitId, cacheKey: thumb.cacheKey, size: size)
    }

    // MARK: - Helpers

    private func browse(_ suffix: String) -> String {
        (space == .personal ? "SYNO.Foto.Browse." : "SYNO.FotoTeam.Browse.") + suffix
    }

    private func additionalParam(_ keys: [String]) -> String {
        "[" + keys.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    private func decoded<T: Decodable>(_ type: T.Type, api: String, method: String, version: Int? = nil, query: [URLQueryItem] = []) async throws -> T {
        let data = try await client.requestData(api: api, method: method, version: version, queryItems: query)
        let envelope: DSMEnvelope<T>
        do {
            envelope = try decoder.decode(DSMEnvelope<T>.self, from: data)
        } catch {
            throw SynologyAPIError.decodingError(error)
        }
        guard envelope.success, let payload = envelope.data else {
            throw FotoError.from(envelope.error?.code ?? -1)
        }
        return payload
    }
}
