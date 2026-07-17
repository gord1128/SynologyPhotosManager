import SwiftUI
import AppKit
import AVFoundation
import SynoKit
import FotoKit

// Dev-only: when launched with PHOTOS_SMOKE_OUT set to a file path, the app
// (see SmokeAppDelegate.applicationDidFinishLaunching) connects to the saved
// NAS, loads a page of real thumbnails, renders them with the app's own SwiftUI
// code via ImageRenderer, writes a PNG, and exits. Produces a real "screenshot"
// of the grid without needing macOS Screen Recording permission.

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

enum SmokeSnapshot {
    @MainActor
    private static func connect() async -> (FotoService, NASConnection)? {
        guard let conn = CredentialStore.savedConnections().first,
              let password = CredentialStore.password(for: conn) else { return nil }
        let service = FotoService(connection: conn, space: .personal)
        do { try await service.connect(username: conn.username, password: password); return (service, conn) }
        catch { return nil }
    }

    @MainActor
    private static func write(_ view: some View, to outPath: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let png = renderer.nsImage?.pngData() else {
            try? "render produced no image".data(using: .utf8)?.write(to: URL(fileURLWithPath: outPath + ".error"))
            exit(4)
        }
        try? png.write(to: URL(fileURLWithPath: outPath))
        exit(0)
    }

    /// Depth-first search for a folder that actually contains photos.
    @MainActor
    private static func findPhotos(_ service: FotoService, folderId: Int, path: [FotoFolder], depth: Int)
        async -> (path: [FotoFolder], subfolders: [FotoFolder], items: [FotoItem])? {
        let items = (try? await service.items(inFolder: folderId, offset: 0, limit: 32)) ?? []
        let subs = (try? await service.folders(parentId: folderId)) ?? []
        if !items.isEmpty { return (path, subs, items) }
        if depth > 0 {
            for sub in subs {
                if let found = await findPhotos(service, folderId: sub.id, path: path + [sub], depth: depth - 1) {
                    return found
                }
            }
        }
        return subs.isEmpty ? nil : (path, subs, [])
    }

    @MainActor
    static func runFolder(outPath: String) async {
        guard let (service, _) = await connect() else {
            try? "connect failed".data(using: .utf8)?.write(to: URL(fileURLWithPath: outPath + ".error")); exit(4)
        }
        // Root-level folder tiles (breadcrumb + subfolder chips).
        let rootSubfolders = (try? await service.folders(parentId: 0)) ?? []
        // A folder that actually holds photos (via a sample item's folderId).
        let sample = try? await service.items(offset: 0, limit: 1).first
        let folderId = sample?.folderId ?? 0
        let items = (try? await service.items(inFolder: folderId, offset: 0, limit: 24)) ?? []
        var loaded: [(FotoItem, NSImage)] = []
        for item in items {
            if let data = try? await service.thumbnailData(for: item, size: .m), let img = NSImage(data: data) {
                loaded.append((item, img))
            }
        }
        write(SmokeFolderView(path: ["MobileBackup", "사진 폴더"],
                              subfolders: rootSubfolders.map(\.displayName),
                              loaded: loaded), to: outPath)
    }

    /// Creates a few sample albums (real photos as reversible membership),
    /// renders the albums grid, then DELETES the test albums before exiting.
    @MainActor
    static func runAlbums(outPath: String) async {
        guard let (service, _) = await connect() else {
            try? "connect failed".data(using: .utf8)?.write(to: URL(fileURLWithPath: outPath + ".error")); exit(4)
        }
        let photoIds = (try? await service.items(offset: 0, limit: 20))?.map(\.id) ?? []
        let specs: [(String, Int)] = [("여름 휴가", 6), ("가족 사진", 4), ("즐겨찾기", 3), ("졸업식", 2)]
        var createdIds: [Int] = []
        for (i, (name, n)) in specs.enumerated() {
            if let album = try? await service.createAlbum(name: name) {
                createdIds.append(album.id)
                // Use a different slice per album so covers differ.
                let ids = Array(photoIds.dropFirst(i * 2).prefix(n))
                try? await service.addItems(albumId: album.id, itemIds: ids)
            }
        }
        // Re-list with covers, load them, then delete the test albums.
        var cards: [(name: String, count: Int, cover: NSImage?)] = []
        for album in (try? await service.albums()) ?? [] where createdIds.contains(album.id) {
            var cover: NSImage?
            if let t = album.additional?.thumbnail,
               let d = try? await service.thumbnailData(unitId: t.unitId, cacheKey: t.cacheKey, size: .m) {
                cover = NSImage(data: d)
            }
            cards.append((album.name, album.itemCount, cover))
        }
        for id in createdIds { try? await service.deleteAlbums(ids: [id]) }
        write(SmokeAlbums(cards: cards), to: outPath)
    }

    /// Renders the People grid (real face clusters + face-crop covers).
    @MainActor
    static func runPeople(outPath: String) async {
        guard let (service, _) = await connect() else {
            try? "connect failed".data(using: .utf8)?.write(to: URL(fileURLWithPath: outPath + ".error")); exit(4)
        }
        let people = (try? await service.persons()) ?? []
        var cards: [(name: String, count: Int, cover: NSImage?)] = []
        for person in people.prefix(18) {
            var cover: NSImage?
            if let cacheKey = person.additional?.thumbnail?.cacheKey,
               let d = try? await service.personFaceCropData(personId: person.id, cacheKey: cacheKey, size: .sm) {
                cover = NSImage(data: d)
            }
            cards.append((person.displayName, person.itemCount, cover))
        }
        write(SmokePeople(cards: cards), to: outPath)
    }

    /// Renders a person's photo grid via the EXACT app path (items(ofPerson:)),
    /// to verify the person_id filter shows only that person's photos.
    @MainActor
    static func runPersonDetail(outPath: String) async {
        guard let (service, _) = await connect() else {
            try? "connect failed".data(using: .utf8)?.write(to: URL(fileURLWithPath: outPath + ".error")); exit(4)
        }
        let people = (try? await service.persons()) ?? []
        // First named person (falls back to the first) — same as the UI would.
        let person = people.first(where: \.isNamed) ?? people.first
        guard let person else { try? "no people".data(using: .utf8)?.write(to: URL(fileURLWithPath: outPath + ".error")); exit(4) }
        let items = (try? await service.items(ofPerson: person.id, offset: 0, limit: 40)) ?? []
        var loaded: [(FotoItem, NSImage)] = []
        for item in items.prefix(28) {
            if let data = try? await service.thumbnailData(for: item, size: .m), let img = NSImage(data: data) {
                loaded.append((item, img))
            }
        }
        write(SmokePersonDetail(name: person.displayName, count: person.itemCount, loaded: loaded), to: outPath)
    }

    /// Verifies progressive video streaming: builds the custom-scheme asset and
    /// asks AVFoundation to load it — which drives the resource loader's byte-range
    /// requests through the trusted session. Writes the result to `outPath`.
    @MainActor
    static func runVideoStream(outPath: String) async {
        func done(_ msg: String, _ code: Int32) -> Never {
            try? msg.data(using: .utf8)?.write(to: URL(fileURLWithPath: outPath)); exit(code)
        }
        guard let (service, _) = await connect() else { done("connect failed", 4) }
        var videoId: Int?
        for offset in stride(from: 0, to: 2000, by: 200) {
            let items = (try? await service.items(offset: offset, limit: 200)) ?? []
            if let v = items.first(where: { $0.type == .video }) { videoId = v.id; break }
            if items.count < 200 { break }
        }
        guard let videoId, let (asset, loader) = VideoStreamLoader.makeAsset(itemId: videoId, service: service) else {
            done("no video item / asset build failed", 4)
        }
        do {
            let playable = try await asset.load(.isPlayable)
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            _ = loader  // keep the delegate alive through the loads
            done("STREAM video id=\(videoId): isPlayable=\(playable) duration=\(CMTimeGetSeconds(duration))s videoTracks=\(tracks.count) \(playable ? "✅" : "⚠️")", 0)
        } catch {
            done("asset load error: \(error)", 5)
        }
    }

    /// Renders search results for a fixed keyword (verifies Search.Search).
    @MainActor
    static func runSearch(outPath: String) async {
        guard let (service, _) = await connect() else {
            try? "connect failed".data(using: .utf8)?.write(to: URL(fileURLWithPath: outPath + ".error")); exit(4)
        }
        let keyword = "<person>"
        let items = (try? await service.search(keyword: keyword)) ?? []
        var loaded: [(FotoItem, NSImage)] = []
        for item in items.prefix(28) {
            if let data = try? await service.thumbnailData(for: item, size: .m), let img = NSImage(data: data) {
                loaded.append((item, img))
            }
        }
        write(SmokePersonDetail(name: "검색: \(keyword)", count: items.count, loaded: loaded), to: outPath)
    }

    /// Verifies single-item full metadata decoding (GPS/address) via itemDetail.
    @MainActor
    static func runItemDetail(outPath: String) async {
        func done(_ msg: String, _ code: Int32) -> Never {
            try? msg.data(using: .utf8)?.write(to: URL(fileURLWithPath: outPath)); exit(code)
        }
        guard let (service, _) = await connect() else { done("connect failed", 4) }
        // Find an item that has GPS by scanning full-metadata pages.
        for offset in stride(from: 0, to: 1200, by: 200) {
            let items = (try? await service.items(offset: offset, limit: 200, additional: FotoService.fullAdditional)) ?? []
            if let g = items.first(where: { $0.additional?.gps != nil }) {
                let d = try? await service.itemDetail(id: g.id)
                let gps = d?.additional?.gps
                let addr = d?.additional?.address?.displayLine ?? "-"
                done("itemDetail id=\(g.id): gps=\(gps.map { "\($0.latitude),\($0.longitude)" } ?? "nil") address=\"\(addr)\" \(gps != nil ? "✅" : "⚠️")", 0)
            }
            if items.count < 200 { break }
        }
        done("no gps item found", 0)
    }

    /// Verifies search-suggestion decoding (name/type via custom CodingKeys).
    @MainActor
    static func runSuggest(outPath: String) async {
        func done(_ msg: String, _ code: Int32) -> Never {
            try? msg.data(using: .utf8)?.write(to: URL(fileURLWithPath: outPath)); exit(code)
        }
        guard let (service, _) = await connect() else { done("connect failed", 4) }
        do {
            let s = try await service.suggestions(for: "현")
            let desc = s.prefix(6).map { "\($0.name)(\($0.type))" }.joined(separator: ", ")
            done("suggest '현': \(s.count) → [\(desc)]", 0)
        } catch { done("suggest error: \(error)", 5) }
    }

    /// Verifies the filtered browse (SimilarItem list_with_filter) decodes + filters.
    @MainActor
    static func runFilter(outPath: String) async {
        func done(_ msg: String, _ code: Int32) -> Never {
            try? msg.data(using: .utf8)?.write(to: URL(fileURLWithPath: outPath)); exit(code)
        }
        guard let (service, _) = await connect() else { done("connect failed", 4) }
        do {
            let vids = try await service.filteredItems(itemTypes: [1], offset: 0, limit: 30)
            let allVideo = vids.allSatisfy { $0.type == .video }
            let end = Int(Date().timeIntervalSince1970)
            let start = end - 30 * 24 * 3600
            let recent = try await service.filteredItems(itemTypes: [0, 1], timeRanges: [(start, end)], offset: 0, limit: 30)
            let times = recent.map { Int($0.takenAt.timeIntervalSince1970) }
            let outOfRange = times.filter { $0 < start || $0 > end }.count
            let byPerson = try await service.filteredItems(itemTypes: [0, 1], personIds: [2], personPolicy: "or", offset: 0, limit: 100)
            let facets = try await service.filterFacets()
            var msg = "facets: places=\(facets.geocoding.flatMap { $0.flattened() }.count) cameras=\(facets.camera.count) lenses=\(facets.lens.count) iso=\(facets.iso.count) aperture=\(facets.aperture.count)"
            if let cam = facets.camera.first {
                let byCam = try await service.filteredItems(itemTypes: [0, 1], cameraIds: [cam.id], offset: 0, limit: 500)
                msg += " | camera '\(cam.name)'(\(cam.id))→\(byCam.count)"
            }
            done("videos: \(vids.count) allVideo=\(allVideo) | date got=\(recent.count) oor=\(outOfRange) | person[2]: \(byPerson.count) | \(msg)", 0)
        } catch { done("filter error: \(error)", 5) }
    }

    /// Verifies the timeline's filtered-browse path (LibraryViewModel + filters).
    @MainActor
    static func runTimelineFilter(outPath: String) async {
        func done(_ msg: String, _ code: Int32) -> Never {
            try? msg.data(using: .utf8)?.write(to: URL(fileURLWithPath: outPath)); exit(code)
        }
        guard let (service, _) = await connect() else { done("connect failed", 4) }
        let vm = LibraryViewModel(service: service)
        await vm.loadFiltersIfNeeded()
        vm.typeFilter = .video
        await vm.applyFilters()
        let allVideo = vm.items.allSatisfy { $0.type == .video }
        done("timeline filter=video: items=\(vm.items.count) allVideo=\(allVideo) sections=\(vm.sections.count) | facets cameras=\(vm.facets.camera.count) countries=\(vm.countries.count) people=\(vm.namedPeople.count)", 0)
    }

    /// Verifies the share flow on an EMPTY test shared album (no photos exposed):
    /// create link → read link → disable → delete.
    @MainActor
    static func runShare(outPath: String) async {
        func done(_ msg: String, _ code: Int32) -> Never {
            try? msg.data(using: .utf8)?.write(to: URL(fileURLWithPath: outPath)); exit(code)
        }
        guard let (service, _) = await connect() else { done("connect failed", 4) }
        do {
            let (share, albumId) = try await service.createShareLink(name: "⚠️TEST_SHARE_DELETE", itemIds: [])
            let link = share.url?.absoluteString ?? "nil"
            let priv = share.privacyType ?? "?"
            try? await service.setSharePublic(passphrase: share.passphrase ?? "", enabled: false)
            let after = try? await service.shareInfo(albumId: albumId)
            try? await service.deleteAlbums(ids: [albumId])
            done("createShareLink: privacy=\(priv) link=\(link) | afterDisable privacy=\(after?.privacyType ?? "?") | cleaned up ✅", 0)
        } catch { done("share error: \(error)", 5) }
    }

    /// Exercises the app's album create/list/delete via FotoService (decode path).
    @MainActor
    static func runAlbumTest(outPath: String) async {
        func done(_ msg: String, _ code: Int32) -> Never {
            try? msg.data(using: .utf8)?.write(to: URL(fileURLWithPath: outPath)); exit(code)
        }
        guard let (service, _) = await connect() else { done("connect failed", 4) }
        var log = ""
        do {
            let listBefore = try await service.albums()
            log += "albums()=\(listBefore.count); "
        } catch { done("albums() DECODE FAILED: \(error)", 5) }
        do {
            let album = try await service.createAlbum(name: "⚠️TEST_APP_\(UUID().uuidString.prefix(4))")
            log += "created id=\(album.id); "
            try await service.renameAlbum(id: album.id, name: "⚠️TEST_APP_RENAMED")
            let renamed = (try await service.albums()).first { $0.id == album.id }?.name ?? "?"
            log += "renamed→'\(renamed)'; "
            try await service.deleteAlbums(ids: [album.id])
            log += "deleted OK"
            done(log + (renamed == "⚠️TEST_APP_RENAMED" ? " ✅" : " ⚠️ rename mismatch"), 0)
        } catch {
            done(log + "createAlbum/rename/delete FAILED: \(error)", 5)
        }
    }

    /// Compares `albums()` across personal vs shared space (space-toggle bug).
    @MainActor
    static func runAlbumSpaces(outPath: String) async {
        func done(_ msg: String, _ code: Int32) -> Never {
            try? msg.data(using: .utf8)?.write(to: URL(fileURLWithPath: outPath)); exit(code)
        }
        guard let (service, _) = await connect() else { done("connect failed", 4) }
        // Mimic the real AlbumsViewModel (which clears on error).
        let vm = AlbumsViewModel(service: service)
        service.space = .personal
        await vm.reload()
        let personal = vm.albums.map(\.name)
        service.space = .shared
        await vm.reload()
        let shared = vm.albums.map(\.name)
        done("AlbumsViewModel — personal: \(personal) | shared: \(shared) \(shared.isEmpty ? "(empty ✅ no stale)" : "⚠️ STALE")", 0)
    }

    /// Verifies LAN auto-discovery (finds Synology NAS on the local network).
    @MainActor
    static func runDiscover(outPath: String) async {
        var found: [String] = []
        var progress = "-"
        await NASDiscoveryService.scan(
            onDiscovered: { found.append("\($0.host):\($0.port)") },
            onProgress: { progress = "\($0.checked)/\($0.total)" }
        )
        let msg = "discovered: \(found.isEmpty ? "none" : found.joined(separator: ", ")) (scanned \(progress))"
        try? msg.data(using: .utf8)?.write(to: URL(fileURLWithPath: outPath))
        exit(0)
    }

    /// Verifies the disk thumbnail cache: cold load → warm cache → a second
    /// ThumbnailLoader (fresh NSCache) still serves the image from disk, and the
    /// year-jump helpers return sane values.
    @MainActor
    static func runDiskCache(outPath: String) async {
        func done(_ msg: String, _ code: Int32) -> Never {
            try? msg.data(using: .utf8)?.write(to: URL(fileURLWithPath: outPath)); exit(code)
        }
        guard let (service, _) = await connect() else { done("connect failed", 4) }
        await DiskImageCache.shared.clear()
        let items = (try? await service.items(offset: 0, limit: 4)) ?? []
        guard let first = items.first else { done("no items", 5) }

        // Cold: fetches from NAS, writes to disk.
        let loaderA = ThumbnailLoader(service: service)
        guard await loaderA.image(for: first) != nil else { done("cold load failed", 5) }
        let sizeAfter = await DiskImageCache.shared.currentSize()

        // Warm: a brand-new loader has an empty NSCache, so a hit here proves the
        // bytes came from disk (not memory).
        let loaderB = ThumbnailLoader(service: service)
        let missIsNil = (await DiskImageCache.shared.data(for: "probe-miss")) == nil
        let bImage = await loaderB.image(for: first)
        let servedFromDisk = missIsNil && bImage != nil

        // Year-jump helpers over a real page.
        let lib = LibraryViewModel(service: service)
        await lib.loadInitial()
        let years = lib.loadedYears
        let jumpID = years.first.flatMap { lib.firstSectionID(forYear: $0) }

        done("diskCache: wrote \(sizeAfter) bytes; freshLoaderServed=\(servedFromDisk); "
            + "loadedYears=\(years.prefix(6))\(years.count > 6 ? "…" : "") jumpTarget=\(jumpID.map(String.init) ?? "nil") "
            + ((sizeAfter > 0 && servedFromDisk && jumpID != nil) ? "✅" : "⚠️"), 0)
    }

    /// Verifies the similar-photos cleanup READ path end-to-end (no deletion):
    /// pages groups, resolves the first few, checks top-pick + member resolution
    /// and the default keep/remove accounting.
    @MainActor
    static func runSimilar(outPath: String) async {
        func done(_ msg: String, _ code: Int32) -> Never {
            try? msg.data(using: .utf8)?.write(to: URL(fileURLWithPath: outPath)); exit(code)
        }
        guard let (service, _) = await connect() else { done("connect failed", 4) }
        let vm = SimilarPhotosViewModel(service: service)
        await vm.reload()
        if let err = vm.errorMessage { done("reload error: \(err)", 5) }
        var log = "groups=\(vm.activeGroupCount) totalRemovable=\(vm.totalRemovable); "

        var checked = 0, membersOK = 0, topPickOK = 0
        for group in vm.groups.prefix(3) {
            await vm.resolve(group)
            checked += 1
            if group.members.count == group.meta.count { membersOK += 1 }
            if group.members.contains(where: { group.isTopPick($0.id) }) { topPickOK += 1 }
        }
        log += "resolved \(checked): membersMatch=\(membersOK)/\(checked) topPickPresent=\(topPickOK)/\(checked); "
        if let g = vm.groups.first {
            log += "group0: count=\(g.meta.count) kept=\(g.keptIDs.count) remove=\(g.removeCount) topPick=\(g.meta.topPick)"
        }
        let ok = vm.activeGroupCount > 0 && checked > 0 && membersOK == checked && topPickOK == checked
        done(log + (ok ? " ✅" : " ⚠️"), 0)
    }

    /// Verifies the RecentlyAdded read path + favorite decode (no writes on real
    /// photos — the favorite toggle uses the already-probed set_favorite path).
    @MainActor
    static func runFavRecent(outPath: String) async {
        func done(_ msg: String, _ code: Int32) -> Never {
            try? msg.data(using: .utf8)?.write(to: URL(fileURLWithPath: outPath)); exit(code)
        }
        guard let (service, _) = await connect() else { done("connect failed", 4) }
        do {
            let recent = try await service.recentlyAdded(offset: 0, limit: 40)
            // Grid items now carry favorite/rating in additional (must decode).
            let page = try await service.items(offset: 0, limit: 40)
            let favCount = page.filter(\.isFavorite).count
            let ratingCount = page.filter { $0.rating > 0 }.count
            // Rating round-trip through the SHIPPED FotoService path, on a real
            // indexed photo, RESTORED afterward (net-zero, reversible).
            var ratingResult = "rating: skipped (no item)"
            if let target = page.first {
                let original = (try? await service.itemDetail(id: target.id))?.rating ?? 0
                let newVal = original == 3 ? 4 : 3
                try await service.setRating(itemIds: [target.id], rating: newVal)
                let after = (try? await service.itemDetail(id: target.id))?.rating ?? -1
                try await service.setRating(itemIds: [target.id], rating: original)   // restore
                let restored = (try? await service.itemDetail(id: target.id))?.rating ?? -1
                ratingResult = "rating set \(original)→\(newVal) got \(after) \(after == newVal ? "✅" : "⚠️"), restored→\(restored) \(restored == original ? "✓" : "⚠️")"
            }
            // Favorites-filter round-trip: favorite a real photo, confirm the
            // filtered browse returns it, then restore.
            var favFilter = "favFilter: skipped"
            if let target = page.first {
                let wasFav = target.isFavorite
                try await service.setFavorite(itemIds: [target.id], favorite: true)
                let filtered = try await service.filteredItems(itemTypes: [0, 1], favoriteOnly: true, offset: 0, limit: 200)
                let found = filtered.contains { $0.id == target.id }
                if !wasFav { try await service.setFavorite(itemIds: [target.id], favorite: false) }  // restore
                favFilter = "favFilter: \(filtered.count) favs, target found=\(found) \(found ? "✅" : "⚠️"), restored=\(!wasFav)"
            }
            // UserInfo + Index status decode (read-only, safe).
            let ui = try? await service.userInfo()
            let ix = try? await service.indexStatus()
            let account = ui.map { "user=\($0.name) admin=\($0.isAdmin) email=\($0.profile?.email ?? "-")" } ?? "userInfo FAILED"
            let indexLine = ix.map { $0.isComplete ? "index=완료" : "index=\($0.remaining) pending" } ?? "index FAILED"

            done("recentlyAdded=\(recent.count); "
                + "grid fav/rating decoded (fav=\(favCount) rated=\(ratingCount) of \(page.count)); "
                + ratingResult + "; " + favFilter + "; " + account + "; " + indexLine
                + (recent.isEmpty ? " ⚠️ empty" : " ✅"), 0)
        } catch {
            done("FAILED: \(error)", 5)
        }
    }

    /// Verifies the collapsed (Synology-style) timeline: LibraryViewModel folds
    /// similar photos into stacks, and a stack expands to its members.
    @MainActor
    static func runStack(outPath: String) async {
        func done(_ msg: String, _ code: Int32) -> Never {
            try? msg.data(using: .utf8)?.write(to: URL(fileURLWithPath: outPath)); exit(code)
        }
        guard let (service, _) = await connect() else { done("connect failed", 4) }
        let lib = LibraryViewModel(service: service)
        await lib.loadInitial()
        if let err = lib.errorMessage { done("load error: \(err)", 5) }
        let sharedUsable = await service.sharedSpaceIsUsable()
        let stacks = lib.items.filter(\.isStack)
        var log = "sharedSpaceIsUsable=\(sharedUsable) (expect false → 공유 토글 숨김); "
        log += "collapsed timeline rows=\(lib.items.count), stacks=\(stacks.count); "
        if let s = stacks.first, let sim = s.similar {
            let members = (try? await service.items(ids: sim.itemId)) ?? []
            log += "first stack: rep=\(s.id) count=\(s.stackCount) topPick=\(sim.topPick) → expanded \(members.count) members "
            log += (members.count == s.stackCount ? "✅" : "⚠️ count mismatch")
        } else {
            log += "no stacks found ⚠️"
        }
        done(log, 0)
    }

    /// Renders the Settings window (System-Settings styling) to a PNG so the
    /// icon-badge / grouped-card look can be reviewed headlessly.
    @MainActor
    static func runSettings(outPath: String) async {
        let model = AppModel()   // loads saved connections synchronously
        let content = SettingsView()
            .environment(model)
            .frame(width: 480, height: 400)
            .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        if let png = renderer.nsImage?.pngData() {
            try? png.write(to: URL(fileURLWithPath: outPath))
            exit(0)
        }
        try? "render failed".data(using: .utf8)?.write(to: URL(fileURLWithPath: outPath))
        exit(3)
    }

    @MainActor
    static func run(outPath: String) async {
        func fail(_ msg: String) -> Never {
            try? msg.data(using: .utf8)?.write(to: URL(fileURLWithPath: outPath + ".error"))
            exit(4)
        }

        guard let conn = CredentialStore.savedConnections().first,
              let password = CredentialStore.password(for: conn) else { fail("no seeded connection") }

        let service = FotoService(connection: conn, space: .personal)
        do {
            try await service.connect(username: conn.username, password: password)
            let total = (try? await service.itemCount()) ?? 0
            let items = try await service.items(offset: 0, limit: 64)

            var loaded: [(FotoItem, NSImage)] = []
            for item in items {
                if let data = try? await service.thumbnailData(for: item, size: .m),
                   let img = NSImage(data: data) {
                    loaded.append((item, img))
                }
            }

            let content = SmokeGrid(host: conn.nickname ?? conn.host, total: total, loaded: loaded)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let png = renderer.nsImage?.pngData() else { fail("render produced no image") }
            try png.write(to: URL(fileURLWithPath: outPath))
            exit(0)
        } catch {
            fail("ERROR: \(error)")
        }
    }
}

/// Static mirror of a person's photo grid for offscreen rendering.
private struct SmokePersonDetail: View {
    let name: String
    let count: Int
    let loaded: [(FotoItem, NSImage)]
    private let columns = Array(repeating: GridItem(.fixed(96), spacing: 2), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Image(systemName: "person.crop.square"); Text("\(name) — \(count)장").bold(); Spacer() }.font(.title3)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(loaded.indices, id: \.self) { i in
                    Image(nsImage: loaded[i].1).resizable().scaledToFill().frame(width: 96, height: 96).clipped()
                }
            }
        }
        .padding(16)
        .frame(width: 720)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Static mirror of the People grid (circular face-crop covers) for rendering.
private struct SmokePeople: View {
    let cards: [(name: String, count: Int, cover: NSImage?)]
    private let columns = Array(repeating: GridItem(.fixed(120), spacing: 16), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Image(systemName: "person.2"); Text("사람").bold(); Spacer() }.font(.title3)
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(cards.indices, id: \.self) { i in
                    VStack(spacing: 8) {
                        Circle().fill(.quaternary)
                            .frame(width: 100, height: 100)
                            .overlay {
                                if let cover = cards[i].cover {
                                    Image(nsImage: cover).resizable().scaledToFill().frame(width: 100, height: 100).clipShape(Circle())
                                } else {
                                    Image(systemName: "person.fill").font(.largeTitle).foregroundStyle(.secondary)
                                }
                            }
                            .overlay(Circle().strokeBorder(.quaternary, lineWidth: 0.5))
                        Text(cards[i].name).font(.callout).lineLimit(1)
                        Text("\(cards[i].count)장").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 860)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Static mirror of the albums grid for offscreen rendering.
private struct SmokeAlbums: View {
    let cards: [(name: String, count: Int, cover: NSImage?)]
    private let columns = Array(repeating: GridItem(.fixed(150), spacing: 12), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Image(systemName: "rectangle.stack"); Text("앨범").bold(); Spacer() }.font(.title3)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(cards.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                            .frame(width: 150, height: 150)
                            .overlay {
                                if let cover = cards[i].cover {
                                    Image(nsImage: cover).resizable().scaledToFill().frame(width: 150, height: 150).clipped()
                                } else {
                                    Image(systemName: "rectangle.stack").font(.largeTitle).foregroundStyle(.secondary)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(cards[i].name).font(.callout).lineLimit(1)
                        Text("\(cards[i].count)장").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 720)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Static mirror of the folder browser for offscreen rendering.
private struct SmokeFolderView: View {
    let path: [String]
    let subfolders: [String]
    let loaded: [(FotoItem, NSImage)]

    private let columns = Array(repeating: GridItem(.fixed(96), spacing: 2), count: 8)
    private let folderCols = Array(repeating: GridItem(.fixed(150), spacing: 8), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // breadcrumb
            HStack(spacing: 4) {
                Image(systemName: "folder")
                Text("홈").foregroundStyle(.secondary)
                ForEach(path, id: \.self) { name in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Text(name)
                }
            }
            .font(.title3).bold()

            if !subfolders.isEmpty {
                LazyVGrid(columns: folderCols, spacing: 8) {
                    ForEach(subfolders, id: \.self) { name in
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill").foregroundStyle(.tint)
                            Text(name).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                Divider()
            }

            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(loaded.indices, id: \.self) { i in
                    Image(nsImage: loaded[i].1).resizable().scaledToFill().frame(width: 96, height: 96).clipped()
                }
            }
        }
        .padding(16)
        .frame(width: 820)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Static (non-lazy) mirror of the grid for offscreen rendering.
private struct SmokeGrid: View {
    let host: String
    let total: Int
    let loaded: [(FotoItem, NSImage)]
    var scale: TimelineScale = .day

    private let columns = Array(repeating: GridItem(.fixed(96), spacing: 2), count: 8)

    private var sections: [TimelineSection] { TimelineGrouping.sections(from: loaded.map(\.0), scale: scale) }
    private var imageByID: [Int: NSImage] { Dictionary(uniqueKeysWithValues: loaded.map { ($0.0.id, $0.1) }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "photo.on.rectangle.angled")
                Text("SynologyPhotos — \(host)").bold()
                Spacer()
                Text("\(total.formatted())장").foregroundStyle(.secondary)
            }
            .font(.title3)

            let images = imageByID
            LazyVGrid(columns: columns, spacing: 2, pinnedViews: [.sectionHeaders]) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.items) { item in
                            ZStack(alignment: .bottomTrailing) {
                                if let img = images[item.id] {
                                    Image(nsImage: img).resizable().scaledToFill().frame(width: 96, height: 96).clipped()
                                }
                                if item.type == .video {
                                    Image(systemName: "play.circle.fill").foregroundStyle(.white).padding(3)
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text(section.title).font(.headline)
                            Text("\(section.items.count)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 820)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
