import Foundation
import CryptoKit
import AppKit
import AVFoundation
import SynoKit

// CAREFUL write/delete spike. Operates ONLY on artifacts it creates (a test
// album, one synthetic uploaded image). NEVER touches the user's real photos.
// Prints an item-count before/after as a safety check. Run one mode at a time:
//   swift run WriteSpike album
//   swift run WriteSpike upload-delete

let mode = CommandLine.arguments.dropFirst().first ?? "album"

// Reuse SynologyMonitor's stored credentials.
SecureLocalStore.appDirectoryName = "SynologyMonitor"
SecureLocalStore.serviceNamespace = "com.synologymonitor"
SecureLocalStore.legacyKeyProvider = {
    let seed = NSUserName() + ":com.synologymonitor.securelocalstore.v1"
    return SymmetricKey(data: SHA256.hash(data: Data(seed.utf8)))
}

guard let connection = CredentialStore.savedConnections().first,
      let password = CredentialStore.password(for: connection) else {
    print("no stored connection/password"); exit(2)
}

let client = SynologyClient(connection: connection, sessionName: "WriteSpike")

func raw(_ api: String, _ method: String, _ query: [URLQueryItem]) async -> [String: Any]? {
    guard let data = try? await client.requestData(api: api, method: method, queryItems: query) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

func rawV(_ api: String, _ method: String, _ version: Int, _ query: [URLQueryItem]) async -> [String: Any]? {
    guard let data = try? await client.requestData(api: api, method: method, version: version, queryItems: query) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

func totalItemCount() async -> Int {
    (await raw("SYNO.Foto.Browse.Item", "count", []))?["data"].flatMap { ($0 as? [String: Any])?["count"] as? Int } ?? -1
}

let writeAPIs = [
    "SYNO.API.Auth",
    "SYNO.Foto.Browse.Item", "SYNO.Foto.Browse.Album", "SYNO.Foto.Browse.NormalAlbum",
    "SYNO.Foto.Upload.Item",
    // Face recognition (personal + shared space).
    "SYNO.Foto.Browse.Person", "SYNO.FotoTeam.Browse.Person",
    "SYNO.FotoTeam.Browse.Item", "SYNO.Foto.Thumbnail", "SYNO.Foto.Download",
    "SYNO.Foto.Browse.GeneralTag", "SYNO.Foto.Search.Search", "SYNO.Foto.Search.Filter",
    "SYNO.Foto.Browse.Geocoding", "SYNO.Foto.Browse.Address",
    "SYNO.Foto.Browse.SimilarItem", "SYNO.Foto.Browse.SimilarTimeline",
]

do {
    // Only the core write APIs are strictly required; Person APIs may be absent
    // on some NAS models, so don't fail discovery if they're missing.
    let requiredAPIs: Set<String> = [
        "SYNO.API.Auth", "SYNO.Foto.Browse.Item", "SYNO.Foto.Browse.Album",
        "SYNO.Foto.Browse.NormalAlbum", "SYNO.Foto.Upload.Item",
    ]
    try await client.discoverAPIs(writeAPIs, required: requiredAPIs, forceRefresh: true)
    try await client.login(username: connection.username, password: password)
    let before = await totalItemCount()
    print("NAS \(connection.id) — real photo count BEFORE: \(before)\n")

    switch mode {
    case "person":
        await personProbe()
    case "person-rename":
        await personRenameProbe()
    case "person-apis":
        await personApiProbe()
    case "person-roundtrip":
        await personRenameRoundtrip()
    case "person-unname":
        await personUnname()
    case "person-jsonset":
        await personJsonSet()
    case "person-cover":
        await personCoverProbe()
    case "person-filter":
        await personFilterProbe()
    case "person-setcover":
        await personSetCoverVerify()
    case "person-audit":
        await personPhotosAudit()
    case "cover-audit":
        await coverAudit()
    case "face-hunt":
        await faceHunt()
    case "face-verify":
        await faceVerify()
    case "people-count":
        await peopleCount()
    case "video-check":
        await videoCheck()
    case "range-check":
        await rangeCheck()
    case "explore":
        await exploreFeatures()
    case "search-probe":
        await searchProbe()
    case "search-filter":
        await searchFilterProbe()
    case "filter-browse":
        await filterBrowseProbe()
    case "filter-more":
        await filterMoreProbe()
    case "places-probe":
        await placesProbe()
    case "exif-facets":
        await exifFacetsProbe()
    case "share-explore":
        await shareExplore()
    case "share-passphrase":
        await sharePassphraseProbe()
    case "share-test":
        await shareTest()
    case "share-apis":
        await shareApisProbe()
    case "share-visibility":
        await shareVisibility()
    case "album-rename":
        await albumRenameProbe()
    case "dupe-probe":
        await dupeProbe()
    case "date-edit":
        await dateEditProbe()
    case "audit":
        await apiAudit()
    case "fav-probe":
        await favRatingProbe()
    case "browse-probe":
        await browseProbe()
    case "stack-probe":
        await stackProbe()
    case "team-probe":
        await teamProbe()
    case "rating-probe":
        await ratingProbe()
    case "reprobe2":
        await reprobe2()
    case "audit2":
        await audit2()
    case "item-detail":
        await itemDetailProbe()
    case "merge-probe":
        await mergeProbe()
    case "album":
        await albumTest()
    case "album-full":
        await albumFullTest()
    case "cleanup":
        await cleanupTestAlbums()
    case "upload-delete":
        await uploadDeleteTest()
    default:
        print("unknown mode: \(mode)")
    }

    let after = await totalItemCount()
    print("\nreal photo count AFTER: \(after)  \(before == after ? "✓ unchanged" : "⚠️ CHANGED — investigate")")
    try? await client.logout()
} catch {
    print("SPIKE FAILED: \(error)")
    exit(1)
}

// MARK: - Person (face-recognition) probe — read-only

func personProbe() async {
    // Try both the personal (SYNO.Foto) and shared (SYNO.FotoTeam) spaces —
    // recognized people may live in either.
    for space in ["SYNO.Foto", "SYNO.FotoTeam"] {
        print("── \(space).Browse.Person list")
        // Vary params to find what this DSM version accepts.
        let paramSets: [[URLQueryItem]] = [
            [URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "20"),
             URLQueryItem(name: "additional", value: "[\"thumbnail\"]")],
            [URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "20"),
             URLQueryItem(name: "additional", value: "[\"thumbnail\"]"),
             URLQueryItem(name: "show_more", value: "true")],
            [URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "20")],
        ]
        var found: [[String: Any]] = []
        for (i, params) in paramSets.enumerated() {
            let resp = await raw("\(space).Browse.Person", "list", params)
            if resp == nil { print("   [set \(i)] no response (API not discovered / not resolvable)"); continue }
            let ok = (resp?["success"] as? Bool) == true
            let err = ((resp?["error"] as? [String: Any])?["code"]).map { "\($0)" }
            let list = ((resp?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
            print("   [set \(i)] success=\(ok) err=\(err ?? "-") people=\(list.count)")
            if list.count > found.count { found = list }
            // Dump the raw data envelope once so we see the real schema.
            if i == 0, let data = resp?["data"] as? [String: Any] {
                print("   data keys: \(data.keys.sorted().joined(separator: ", "))")
            }
        }
        for p in found.prefix(10) {
            let name = (p["name"] as? String) ?? ""
            let id = p["id"] as? Int ?? -1
            let count = p["item_count"] as? Int ?? -1
            print("   • id=\(id) name=\"\(name.isEmpty ? "(unnamed)" : name)\" items=\(count)  keys=\(p.keys.sorted().joined(separator: ","))")
        }
        // Dump the cover/additional shape of the first person so we can model it.
        if space == "SYNO.Foto", let first = found.first {
            print("   cover raw: \(first["cover"] ?? "nil")")
            print("   additional raw: \(first["additional"] ?? "nil")")
            let cover = first["cover"] as? Int ?? -1
            let cacheKey = ((first["additional"] as? [String: Any])?["thumbnail"] as? [String: Any])?["cache_key"] as? String ?? ""
            let prefix = Int(cacheKey.split(separator: "_").first ?? "") ?? -1
            // Which id+type does SYNO.Foto.Thumbnail accept for a person cover?
            let combos: [(Int, String, String)] = [
                (cover, "unit", "cover+unit"),
                (prefix, "unit", "prefix+unit"),
                (cover, "person", "cover+person"),
                (prefix, "person", "prefix+person"),
            ]
            for (idVal, type, label) in combos {
                do {
                    let bytes = try await client.requestData(api: "SYNO.Foto.Thumbnail", method: "get", queryItems: [
                        URLQueryItem(name: "id", value: "\(idVal)"),
                        URLQueryItem(name: "cache_key", value: cacheKey),
                        URLQueryItem(name: "type", value: type),
                        URLQueryItem(name: "size", value: "sm"),
                    ])
                    let isImage = bytes.count > 1000
                    print("   thumb \(label) id=\(idVal): \(bytes.count)B \(isImage ? "✓ IMAGE" : "(small)")")
                } catch {
                    print("   thumb \(label) id=\(idVal): ✘ \(error)")
                }
            }
        }
        // If we found people, verify we can list one person's photos.
        if let first = found.first, let pid = first["id"] as? Int {
            let itemAPI = "\(space).Browse.Item"
            for filterKey in ["person", "person_id"] {
                let items = await raw(itemAPI, "list", [
                    URLQueryItem(name: filterKey, value: "\(pid)"),
                    URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "3"),
                ])
                let ok = (items?["success"] as? Bool) == true
                let list = ((items?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
                let err = ((items?["error"] as? [String: Any])?["code"]).map { "\($0)" }
                print("   person \(pid) photos via \(filterKey)=: success=\(ok) items=\(list.count) err=\(err ?? "-")")
            }
        }
    }
}

// MARK: - Find the person-MERGE method (safe: uses non-existent ids, no real merge)

func mergeProbe() async {
    // Fake ids so that even if a method executes, there's nothing real to merge.
    let a = "999999991", b = "999999992"
    print("── method existence on SYNO.Foto.Browse.Person (fake ids \(a)/\(b)):")
    let methods: [(String, [URLQueryItem])] = [
        ("merge", [URLQueryItem(name: "id", value: "[\(a)]"), URLQueryItem(name: "target", value: b)]),
        ("merge", [URLQueryItem(name: "source_id", value: a), URLQueryItem(name: "target_id", value: b)]),
        ("merge", [URLQueryItem(name: "id", value: a), URLQueryItem(name: "target_id", value: b)]),
        ("combine", [URLQueryItem(name: "id", value: "[\(a)]"), URLQueryItem(name: "target", value: b)]),
        ("group", [URLQueryItem(name: "id", value: "[\(a)]")]),
        ("add_person", [URLQueryItem(name: "id", value: a)]),
        ("move_item", [URLQueryItem(name: "id", value: a)]),
    ]
    for (m, q) in methods {
        let r = await raw("SYNO.Foto.Browse.Person", m, q)
        let code = ((r?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
        let ok = (r?["success"] as? Bool) == true
        print("   \(m) [\(q.map(\.name).joined(separator: ","))]: success=\(ok) err=\(code)\(code == "103" ? " (absent)" : code == "-" ? " (?nil)" : " (EXISTS)")")
    }
}

// MARK: - Can we fetch ONE item's full metadata (gps/address/exif) by id?

func itemDetailProbe() async {
    func jstr(_ v: Any?) -> String {
        guard let v, let d = try? JSONSerialization.data(withJSONObject: v), let s = String(data: d, encoding: .utf8) else { return "\(v ?? "nil")" }
        return s
    }
    let full = "[\"thumbnail\",\"resolution\",\"orientation\",\"exif\",\"gps\",\"address\",\"video_meta\"]"
    // Find an item that HAS gps (scan a few pages with gps additional).
    var target = -1
    for offset in stride(from: 0, to: 1200, by: 200) {
        let r = await raw("SYNO.Foto.Browse.Item", "list", [
            URLQueryItem(name: "offset", value: "\(offset)"), URLQueryItem(name: "limit", value: "200"),
            URLQueryItem(name: "additional", value: full),
        ])
        let list = ((r?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
        if let g = list.first(where: { (($0["additional"] as? [String: Any])?["gps"]) != nil }) { target = g["id"] as? Int ?? -1; break }
        if list.count < 200 { break }
    }
    print("item with gps: id=\(target)")

    // Try get-by-id shapes.
    for (method, key, val) in [("get", "id", "\(target)"), ("get", "id", "[\(target)]"), ("list", "id", "[\(target)]")] {
        let r = await raw("SYNO.Foto.Browse.Item", method, [
            URLQueryItem(name: key, value: val),
            URLQueryItem(name: "additional", value: full),
        ])
        let code = ((r?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
        let data = r?["data"] as? [String: Any]
        let item = (data?["list"] as? [[String: Any]])?.first ?? data
        let add = item?["additional"] as? [String: Any]
        print("  \(method) \(key)=\(val): err=\(code) addKeys=\(add?.keys.sorted() ?? []) gps=\(jstr(add?["gps"])) addr=\(jstr(add?["address"]))")
    }
}

// MARK: - Audit round 2: Index status, UserInfo, Category, Tags, Smart albums

func audit2() async {
    func data(_ r: [String: Any]?) -> [String: Any]? { r?["data"] as? [String: Any] }
    func list(_ r: [String: Any]?) -> [[String: Any]] { (data(r)?["list"] as? [[String: Any]]) ?? [] }

    // Discover the candidate APIs first (else raw/rawV can't route them).
    try? await client.discoverAPIs([
        "SYNO.Foto.Index", "SYNO.Foto.UserInfo", "SYNO.Foto.Browse.Category",
        "SYNO.Foto.Browse.GeneralTag", "SYNO.Foto.Browse.ConditionAlbum",
    ], required: [], forceRefresh: true)

    // 1) INDEX STATUS (read-only, safe) — genuinely useful diagnostic.
    print("── Index.get (indexing progress):")
    let idx = await rawV("SYNO.Foto.Index", "get", 1, [])
    if let d = data(idx) {
        for (k, v) in d.sorted(by: { $0.key < $1.key }) { print("   \(k) = \(v)") }
    } else { print("   FAILED err=\(((idx?["error"] as? [String:Any])?["code"]).map{"\($0)"} ?? "-")") }

    // 2) USERINFO (read-only).
    print("\n── UserInfo.me:")
    let me = await rawV("SYNO.Foto.UserInfo", "me", 1, [])
    print("   \(data(me) ?? [:])")

    // 3) CATEGORY — does it browse where Concept doesn't?
    print("\n── Category.get + browse:")
    let cat = await rawV("SYNO.Foto.Browse.Category", "get", 4, [])
    let cats = list(cat)
    print("   categories=\(cats.count) sampleKeys=\(cats.first?.keys.sorted() ?? [])")
    for c in cats.prefix(6) { print("      \(c)") }

    // 4) TAGS — create a test tag, list, try to attach to a real photo, browse, cleanup.
    print("\n── GeneralTag:")
    let tagName = "⚠️TEST_TAG_\(UUID().uuidString.prefix(6))"
    let created = await rawV("SYNO.Foto.Browse.GeneralTag", "create", 2, [URLQueryItem(name:"name",value:"\"\(tagName)\"")])
    let tagId = (data(created)?["tag"] as? [String:Any])?["id"] as? Int ?? (data(created)?["id"] as? Int)
    print("   create '\(tagName)': success=\((created?["success"] as? Bool) == true) id=\(tagId.map(String.init) ?? "?") data=\(data(created) ?? [:])")
    let tags = await rawV("SYNO.Foto.Browse.GeneralTag", "list", 2, [URLQueryItem(name:"offset",value:"0"),URLQueryItem(name:"limit",value:"20")])
    print("   list tags=\(list(tags).count)")
    if let tid = tagId {
        // Try to TAG a real photo (then remove). Probe several shapes.
        let firstItem = list(await raw("SYNO.Foto.Browse.Item","list",[URLQueryItem(name:"limit",value:"1")])).first?["id"] as? Int
        if let iid = firstItem {
            for (label, method, extra) in [
                ("Item.set general_tag", "set", [URLQueryItem(name:"id",value:"[\(iid)]"),URLQueryItem(name:"general_tag",value:"[\(tid)]")]),
                ("Item.add_tag", "add_tag", [URLQueryItem(name:"id",value:"[\(iid)]"),URLQueryItem(name:"tag",value:"[\(tid)]")]),
                ("GeneralTag.add_item", "add_item", [URLQueryItem(name:"id",value:"\(tid)"),URLQueryItem(name:"item",value:"[\(iid)]")]),
            ] {
                let r = await rawV("SYNO.Foto.Browse."+(label.hasPrefix("GeneralTag") ? "GeneralTag":"Item"), method, 2, extra)
                let ok = (r?["success"] as? Bool) == true
                let code = ((r?["error"] as? [String:Any])?["code"]).map{"\($0)"} ?? "-"
                print("   tag-attach [\(label)]: success=\(ok) err=\(code)")
            }
            // Browse by tag (does list_with_filter general_tag work?).
            let byTag = await rawV("SYNO.Foto.Browse.SimilarItem","list_with_filter",2,[URLQueryItem(name:"general_tag",value:"[\(tid)]"),URLQueryItem(name:"item_type",value:"[0,1]"),URLQueryItem(name:"limit",value:"10")])
            print("   browse by tag: count=\(list(byTag).count)")
        }
        _ = await rawV("SYNO.Foto.Browse.GeneralTag","delete",2,[URLQueryItem(name:"id",value:"[\(tid)]")])
        print("   deleted test tag")
    }

    // 5) SMART ALBUM (ConditionAlbum) — create with a simple condition, verify, delete.
    print("\n── ConditionAlbum (smart album):")
    let sug = await rawV("SYNO.Foto.Browse.ConditionAlbum","suggest",4,[URLQueryItem(name:"keyword",value:"2024")])
    print("   suggest('2024'): success=\((sug?["success"] as? Bool) == true) data=\(data(sug).map { "\($0.keys.sorted())" } ?? "-")")
    for condJSON in ["{\"general_tag\":[]}", "[]", "{\"time\":[{\"start_time\":1704067200,\"end_time\":1735689599}]}"] {
        let c = await rawV("SYNO.Foto.Browse.ConditionAlbum","create",4,[URLQueryItem(name:"name",value:"\"⚠️TEST_SMART_\(UUID().uuidString.prefix(4))\""),URLQueryItem(name:"condition",value:condJSON)])
        let ok = (c?["success"] as? Bool) == true
        let code = ((c?["error"] as? [String:Any])?["code"]).map{"\($0)"} ?? "-"
        let aid = (data(c)?["album"] as? [String:Any])?["id"] as? Int ?? (data(c)?["id"] as? Int)
        print("   create condition=\(condJSON): success=\(ok) err=\(code) id=\(aid.map(String.init) ?? "?")")
        if let aid { _ = await raw("SYNO.Foto.Browse.Album","delete",[URLQueryItem(name:"id",value:"[\(aid)]")]); print("      deleted test smart album \(aid)"); break }
    }
}

// MARK: - Re-probe deferred features (favorites collection + AI concepts), the
//         RIGHT way: with a REAL favorited photo present, and stable versions.

func reprobe2() async {
    func count(_ r: [String: Any]?) -> Int { ((r?["data"] as? [String: Any])?["list"] as? [[String: Any]])?.count ?? -1 }
    func ids(_ r: [String: Any]?) -> [Int] { (((r?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? Int } }

    // ---- FAVORITES COLLECTION: favorite a REAL photo, then see what lists it ----
    print("── favorites collection (with a real favorite present):")
    let list = await raw("SYNO.Foto.Browse.Item", "list", [URLQueryItem(name:"offset",value:"0"),URLQueryItem(name:"limit",value:"1")])
    guard let realId = ids(list).first else { print("  no item"); return }
    _ = await raw("SYNO.Foto.Browse.Item", "set_favorite", [URLQueryItem(name:"id",value:"[\(realId)]"),URLQueryItem(name:"favorite",value:"true")])
    print("  favorited real id=\(realId)")

    let f1 = await rawV("SYNO.Foto.Browse.SimilarItem","list_with_filter",2,[URLQueryItem(name:"favorite",value:"true"),URLQueryItem(name:"item_type",value:"[0,1]"),URLQueryItem(name:"offset",value:"0"),URLQueryItem(name:"limit",value:"50")])
    print("  SimilarItem list_with_filter favorite=true → count=\(count(f1)) contains? \(ids(f1).contains(realId))")
    let f2 = await raw("SYNO.Foto.Browse.Item","list",[URLQueryItem(name:"offset",value:"0"),URLQueryItem(name:"limit",value:"3000"),URLQueryItem(name:"additional",value:"[\"favorite\"]")])
    let favInList = (((f2?["data"] as? [String:Any])?["list"] as? [[String:Any]]) ?? []).filter { (($0["additional"] as? [String:Any])?["favorite"] as? Bool) == true }
    print("  Item.list scan additional.favorite==true → \(favInList.count) (contains? \(favInList.contains { ($0["id"] as? Int) == realId }))")
    let f3 = await rawV("SYNO.Foto.Favorite","list",2,[URLQueryItem(name:"offset",value:"0"),URLQueryItem(name:"limit",value:"50")])
    print("  Favorite.list v2 → success=\((f3?["success"] as? Bool) == true) count=\(count(f3)) err=\(((f3?["error"] as? [String:Any])?["code"]).map{"\($0)"} ?? "-")")

    _ = await raw("SYNO.Foto.Browse.Item", "set_favorite", [URLQueryItem(name:"id",value:"[\(realId)]"),URLQueryItem(name:"favorite",value:"false")])
    print("  restored (unfavorited) id=\(realId)")

    // ---- AI CONCEPTS: which version is stable, and how to browse a concept ----
    print("\n── concepts (stability + item browse):")
    for v in [1, 2] {
        let a = await rawV("SYNO.Foto.Browse.Concept","list",v,[URLQueryItem(name:"offset",value:"0"),URLQueryItem(name:"limit",value:"30")])
        let b = await rawV("SYNO.Foto.Browse.Concept","list",v,[URLQueryItem(name:"offset",value:"0"),URLQueryItem(name:"limit",value:"30")])
        print("  Concept.list v\(v): run1=\(count(a)) run2=\(count(b))  sampleKeys=\(( ((a?["data"] as? [String:Any])?["list"] as? [[String:Any]])?.first?.keys.sorted()) ?? [])")
    }
    // Get a working concept list, then browse its items.
    let cr = await rawV("SYNO.Foto.Browse.Concept","list",1,[URLQueryItem(name:"offset",value:"0"),URLQueryItem(name:"limit",value:"40")])
    let concepts = ((cr?["data"] as? [String:Any])?["list"] as? [[String:Any]]) ?? []
    if let c = concepts.first(where: { ($0["item_count"] as? Int ?? 0) > 0 }), let cid = c["id"] as? Int {
        print("  browse concept id=\(cid) '\(c["name"] ?? "")' (item_count=\(c["item_count"] ?? "?")):")
        print("    Item.list general_tag=[id]: \(count(await raw("SYNO.Foto.Browse.Item",[URLQueryItem(name:"general_tag",value:"[\(cid)]"),URLQueryItem(name:"limit",value:"10")],"list")))")
        print("    list_with_filter general_tag=[id]: \(count(await rawV("SYNO.Foto.Browse.SimilarItem","list_with_filter",2,[URLQueryItem(name:"general_tag",value:"[\(cid)]"),URLQueryItem(name:"item_type",value:"[0,1]"),URLQueryItem(name:"limit",value:"10")])))")
        print("    list_with_filter concept=[id]: \(count(await rawV("SYNO.Foto.Browse.SimilarItem","list_with_filter",2,[URLQueryItem(name:"concept",value:"[\(cid)]"),URLQueryItem(name:"item_type",value:"[0,1]"),URLQueryItem(name:"limit",value:"10")])))")
        print("    Item.list concept_id=id: \(count(await raw("SYNO.Foto.Browse.Item",[URLQueryItem(name:"concept_id",value:"\(cid)"),URLQueryItem(name:"limit",value:"10")],"list")))")
    } else { print("  no concept with items to browse (concepts=\(concepts.count))") }
}

// MARK: - Rating, harder: correct maxVersion, unique upload, then a real-photo
//         round-trip WITH restore (rating is reversible → net-zero, safe).

func makeUniqueJPEG() -> Data {
    let size = NSSize(width: 96, height: 96)
    let img = NSImage(size: size)
    img.lockFocus()
    for _ in 0..<40 {   // random rects → unique content hash every run
        NSColor(calibratedRed: .random(in: 0...1), green: .random(in: 0...1), blue: .random(in: 0...1), alpha: 1).setFill()
        NSRect(x: .random(in: 0...96), y: .random(in: 0...96), width: .random(in: 4...40), height: .random(in: 4...40)).fill()
    }
    img.unlockFocus()
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return Data() }
    return jpeg
}

func ratingProbe() async {
    let itemMaxV = client.endpoint(for: "SYNO.Foto.Browse.Item")?.maxVersion ?? 1
    print("── Browse.Item maxVersion = \(itemMaxV)")

    func readRating(_ id: Int) async -> Int? {
        let r = await raw("SYNO.Foto.Browse.Item", "get", [
            URLQueryItem(name: "id", value: "[\(id)]"),
            URLQueryItem(name: "additional", value: "[\"rating\"]")])
        let it = ((r?["data"] as? [String: Any])?["list"] as? [[String: Any]])?.first
        return (it?["additional"] as? [String: Any])?["rating"] as? Int ?? it?["rating"] as? Int
    }
    func trySet(_ id: Int, _ rating: Int, version: Int, ratingParam: String = "rating", asArray: Bool = false) async -> (Bool, Int?) {
        let val = asArray ? "[\(rating)]" : "\(rating)"
        let r = await rawV("SYNO.Foto.Browse.Item", "set", version, [
            URLQueryItem(name: "id", value: "[\(id)]"), URLQueryItem(name: ratingParam, value: val)])
        let ok = (r?["success"] as? Bool) == true
        return (ok, await readRating(id))
    }

    // 1) Unique synthetic upload → rating at maxVersion + fallbacks.
    let filename = "SYNOPHOTOS_RATETEST_\(UUID().uuidString.prefix(8)).jpg"
    let jpeg = makeUniqueJPEG()
    let mtime = String(Int(Date().timeIntervalSince1970 * 1000))
    let up: [String: Any]? = await {
        guard let data = try? await client.requestMultipart(api: "SYNO.Foto.Upload.Item", extraQuery: [
            URLQueryItem(name: "api", value: "SYNO.Foto.Upload.Item"),
            URLQueryItem(name: "method", value: "upload"), URLQueryItem(name: "version", value: "8"),
        ], pathSuffix: "SYNO.Foto.Upload.Item", build: { _, _ in
            let b = "----ws\(UUID().uuidString)"; var body = Data()
            func f(_ n: String, _ v: String) { body.append("--\(b)\r\nContent-Disposition: form-data; name=\"\(n)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!) }
            f("api","SYNO.Foto.Upload.Item"); f("method","upload"); f("version","8")
            f("uploadDestination","\"timeline\""); f("duplicate","\"ignore\""); f("name","\"\(filename)\""); f("mtime",mtime); f("folder","[\"PhotoLibrary\"]")
            body.append("--\(b)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append(jpeg); body.append("\r\n--\(b)--\r\n".data(using: .utf8)!)
            return ("multipart/form-data; boundary=\(b)", body)
        }) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }()
    if let d = up?["data"] as? [String: Any], let id = d["id"] as? Int ?? d["item_id"] as? Int {
        print("\n── synthetic upload id=\(id), before rating=\(await readRating(id).map(String.init) ?? "?")")
        for (label, v, param, arr) in [("maxV \(itemMaxV)", itemMaxV, "rating", false), ("maxV array", itemMaxV, "rating", true), ("v1", 1, "rating", false)] as [(String,Int,String,Bool)] {
            let (ok, now) = await trySet(id, 4, version: v, ratingParam: param, asArray: arr)
            print("   set rating=4 [\(label)]: success=\(ok) → rating=\(now.map(String.init) ?? "?")")
            if now == 4 { print("   ✅ synthetic rating works via \(label)"); break }
        }
        _ = await raw("SYNO.Foto.Browse.Item", "delete", [URLQueryItem(name: "id", value: "[\(id)]")])
        print("   cleaned up synthetic \(filename)")
    } else { print("upload failed: \(up ?? [:])") }

    // 2) If synthetic never persisted, test on a REAL indexed photo with RESTORE.
    print("\n── real-photo round-trip (restored to original afterward):")
    let list = await raw("SYNO.Foto.Browse.Item", "list", [
        URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "1"),
        URLQueryItem(name: "additional", value: "[\"rating\"]")])
    guard let realId = ((list?["data"] as? [String: Any])?["list"] as? [[String: Any]])?.first?["id"] as? Int else {
        print("   no real item"); return
    }
    let original = await readRating(realId) ?? 0
    print("   real id=\(realId), original rating=\(original)")
    let target = original == 3 ? 4 : 3
    let (ok, now) = await trySet(realId, target, version: itemMaxV)
    print("   set rating=\(target) [maxV]: success=\(ok) → rating=\(now.map(String.init) ?? "?") \(now == target ? "✅ WORKS on real photo" : "⚠️ still ignored")")
    // RESTORE original no matter what.
    let (rok, restored) = await trySet(realId, original, version: itemMaxV)
    print("   restored to \(original): success=\(rok) → rating=\(restored.map(String.init) ?? "?") \(restored == original ? "✓" : "⚠️ VERIFY MANUALLY id=\(realId)")")
}

// MARK: - Shared (Team) space: is it really usable, or does it 801?

func teamProbe() async {
    try? await client.discoverAPIs([
        "SYNO.FotoTeam.Browse.Item", "SYNO.FotoTeam.Browse.Album",
        "SYNO.FotoTeam.Browse.Timeline", "SYNO.FotoTeam.Settings",
    ], required: [], forceRefresh: true)
    print("── FotoTeam API availability:")
    for api in ["SYNO.FotoTeam.Browse.Item", "SYNO.FotoTeam.Browse.Album", "SYNO.FotoTeam.Browse.Timeline"] {
        print("   \(api): \(client.endpoint(for: api) != nil ? "present" : "ABSENT")")
    }
    print("── FotoTeam queries (what the 공유 toggle triggers):")
    for (api, m, q) in [
        ("SYNO.FotoTeam.Browse.Item", "count", []),
        ("SYNO.FotoTeam.Browse.Item", "list", [URLQueryItem(name:"offset",value:"0"),URLQueryItem(name:"limit",value:"5")]),
        ("SYNO.FotoTeam.Browse.Album", "list", [URLQueryItem(name:"offset",value:"0"),URLQueryItem(name:"limit",value:"5")]),
    ] {
        let r = await raw(api, m, q)
        let ok = (r?["success"] as? Bool) == true
        let code = ((r?["error"] as? [String:Any])?["code"]).map { "\($0)" } ?? "-"
        print("   \(api) \(m): success=\(ok) err=\(code)")
    }
}

// MARK: - Stack behaviour: collapsed timeline + expand-a-stack (Synology-exact)

func stackProbe() async {
    // 1) Collapsed timeline: SimilarItem.list (NO id). Representatives carry
    //    `similar`; find one with a real group (count>1).
    let page = await rawV("SYNO.Foto.Browse.SimilarItem", "list", 2, [
        URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "200"),
        URLQueryItem(name: "additional", value: "[\"thumbnail\"]"),
        URLQueryItem(name: "sort_by", value: "takentime"), URLQueryItem(name: "sort_direction", value: "desc"),
    ])
    let list = ((page?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
    let stacked = list.filter { ($0["similar"] as? [String: Any]) != nil }
    print("── collapsed timeline: \(list.count) rows, \(stacked.count) are stacks")
    guard let rep = stacked.first, let repId = rep["id"] as? Int,
          let sim = rep["similar"] as? [String: Any] else { print("no stack found"); return }
    let count = sim["count"] as? Int ?? 0
    let topPick = sim["top_pick"] as? Int ?? 0
    let roster = (sim["item_id"] as? [Int]) ?? []
    print("   stack rep id=\(repId) count=\(count) top_pick=\(topPick) rosterSize=\(roster.count)")
    print("   is rep == top_pick? \(repId == topPick)")

    // 2) Expand the stack: SimilarItem.list with id=<repId> (scalar).
    let exp = await rawV("SYNO.Foto.Browse.SimilarItem", "list", 2, [
        URLQueryItem(name: "id", value: "\(repId)"),
        URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "100"),
        URLQueryItem(name: "additional", value: "[\"thumbnail\"]"),
    ])
    let members = ((exp?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
    let memberIds = members.compactMap { $0["id"] as? Int }
    print("   expand SimilarItem.list id=\(repId) → \(members.count) members: \(memberIds.prefix(8))")
    print("   members == count? \(members.count == count)   roster⊆members? \(Set(roster).isSubset(of: Set(memberIds)))")
    print("   member has thumbnail? \((members.first?["additional"] as? [String: Any])?["thumbnail"] != nil)")
    print("   member carries its own 'similar'? \(members.first?["similar"] != nil)")

    // 3) Is id honored? Small limit: if it returns limit → id IGNORED.
    func expandCount(_ id: Int, limit: Int, param: String, v: Int) async -> Int {
        let r = await rawV("SYNO.Foto.Browse.SimilarItem", "list", v, [
            URLQueryItem(name: param, value: "\(id)"),
            URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "\(limit)")])
        return ((r?["data"] as? [String: Any])?["list"] as? [[String: Any]])?.count ?? -1
    }
    print("\n── is the id param honored? (expect \(count) if yes, \(min(15,count)) filtered)")
    print("   id=\(repId) limit=15: \(await expandCount(repId, limit: 15, param: "id", v: 2))")
    print("   similar_id=\(repId) limit=15: \(await expandCount(repId, limit: 15, param: "similar_id", v: 2))")
    // 4) Roster via Browse.Item get (the M4-proven expansion path).
    let ros = await raw("SYNO.Foto.Browse.Item", "get", [
        URLQueryItem(name: "id", value: "[" + roster.map(String.init).joined(separator: ",") + "]"),
        URLQueryItem(name: "additional", value: "[\"thumbnail\"]")])
    let rosItems = ((ros?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
    print("   Browse.Item get roster[\(roster.count)] → \(rosItems.count) items (M4 path)")
}

// MARK: - How to LIST favorites, and browse a Concept's items

func browseProbe() async {
    func show(_ label: String, _ r: [String: Any]?) {
        let ok = (r?["success"] as? Bool) == true
        let code = ((r?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
        let list = (r?["data"] as? [String: Any])?["list"] as? [[String: Any]]
        print("   \(label): ok=\(ok) err=\(code) count=\(list?.count ?? -1)" + (list?.first.map { " keys=\($0.keys.sorted().prefix(9))" } ?? ""))
    }
    print("── favorites listing options:")
    show("Favorite.list", await rawV("SYNO.Foto.Favorite", "list", 1, [URLQueryItem(name:"offset",value:"0"),URLQueryItem(name:"limit",value:"20")]))
    show("Item.list favorite=true", await raw("SYNO.Foto.Browse.Item", "list", [URLQueryItem(name:"offset",value:"0"),URLQueryItem(name:"limit",value:"20"),URLQueryItem(name:"favorite",value:"true")]))
    show("SimilarItem list_with_filter favorite=true", await rawV("SYNO.Foto.Browse.SimilarItem", "list_with_filter", 2, [URLQueryItem(name:"favorite",value:"true"),URLQueryItem(name:"offset",value:"0"),URLQueryItem(name:"limit",value:"20"),URLQueryItem(name:"item_type",value:"[0,1]")]))

    // Does favorite=true actually FILTER? Compare its total to the library total.
    let total = await totalItemCount()
    let favAll = await raw("SYNO.Foto.Browse.Item", "list", [URLQueryItem(name:"offset",value:"0"),URLQueryItem(name:"limit",value:"5000"),URLQueryItem(name:"favorite",value:"true")])
    let favCount = ((favAll?["data"] as? [String: Any])?["list"] as? [[String: Any]])?.count ?? -1
    print("   → favorite=true returns \(favCount) of \(total) total → \(favCount == total ? "IGNORED (not filtering)" : "FILTERS ✅")")

    print("\n── concepts (list WITHOUT additional) + how to get a concept's items:")
    let cr = await rawV("SYNO.Foto.Browse.Concept", "list", 2, [URLQueryItem(name:"offset",value:"0"),URLQueryItem(name:"limit",value:"25")])
    let concepts = (cr?["data"] as? [String: Any])?["list"] as? [[String: Any]] ?? []
    print("   concepts=\(concepts.count); sample keys=\(concepts.first?.keys.sorted() ?? [])")
    for c in concepts.prefix(8) { print("      id=\(c["id"] ?? "?") name='\(c["name"] ?? "?")' count=\(c["item_count"] ?? "?")") }
    if let first = concepts.first(where: { ($0["item_count"] as? Int ?? 0) > 0 }) ?? concepts.first, let cid = first["id"] as? Int {
        print("   → items of concept \(cid) '\(first["name"] ?? "")':")
        show("Item.list general_tag=[id]", await raw("SYNO.Foto.Browse.Item", [URLQueryItem(name:"general_tag",value:"[\(cid)]"),URLQueryItem(name:"offset",value:"0"),URLQueryItem(name:"limit",value:"10"),URLQueryItem(name:"additional",value:"[\"thumbnail\"]")], "list"))
        show("SimilarItem list_with_filter general_tag=[id]", await rawV("SYNO.Foto.Browse.SimilarItem","list_with_filter",2,[URLQueryItem(name:"general_tag",value:"[\(cid)]"),URLQueryItem(name:"item_type",value:"[0,1]"),URLQueryItem(name:"offset",value:"0"),URLQueryItem(name:"limit",value:"10"),URLQueryItem(name:"additional",value:"[\"thumbnail\"]")]))
        show("SimilarItem list_with_filter concept=[id]", await rawV("SYNO.Foto.Browse.SimilarItem","list_with_filter",2,[URLQueryItem(name:"concept",value:"[\(cid)]"),URLQueryItem(name:"item_type",value:"[0,1]"),URLQueryItem(name:"offset",value:"0"),URLQueryItem(name:"limit",value:"10"),URLQueryItem(name:"additional",value:"[\"thumbnail\"]")]))
    }
}

// helper overload: raw with explicit method as last arg (readability at call site)
func raw(_ api: String, _ query: [URLQueryItem], _ method: String) async -> [String: Any]? {
    await raw(api, method, query)
}

// MARK: - Favorite / rating: how is state READ, and does the write round-trip?

func favRatingProbe() async {
    // 1) Which additional key surfaces favorite/rating on Item.list?
    print("── Item.list additional probe:")
    for add in ["[\"favorite\"]", "[\"rating\"]", "[\"favorite\",\"rating\"]", "[\"tag\"]"] {
        let r = await raw("SYNO.Foto.Browse.Item", "list", [
            URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "3"),
            URLQueryItem(name: "additional", value: add)])
        let ok = (r?["success"] as? Bool) == true
        let first = ((r?["data"] as? [String: Any])?["list"] as? [[String: Any]])?.first
        let topKeys = first?.keys.sorted() ?? []
        let addKeys = (first?["additional"] as? [String: Any])?.keys.sorted() ?? []
        print("   additional=\(add): ok=\(ok) itemKeys=\(topKeys) additionalKeys=\(addKeys)")
    }

    // 2) Round-trip on a TEST upload (favorite + rating), then delete it.
    let filename = "SYNOPHOTOS_FAVTEST_\(UUID().uuidString.prefix(8)).jpg"
    let jpeg = makeTestJPEG()
    let mtime = String(Int(Date().timeIntervalSince1970 * 1000))
    let up: [String: Any]? = await {
        guard let data = try? await client.requestMultipart(api: "SYNO.Foto.Upload.Item", extraQuery: [
            URLQueryItem(name: "api", value: "SYNO.Foto.Upload.Item"),
            URLQueryItem(name: "method", value: "upload"), URLQueryItem(name: "version", value: "8"),
        ], pathSuffix: "SYNO.Foto.Upload.Item", build: { _, _ in
            let b = "----ws\(UUID().uuidString)"; var body = Data()
            func f(_ n: String, _ v: String) {
                body.append("--\(b)\r\nContent-Disposition: form-data; name=\"\(n)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!)
            }
            f("api","SYNO.Foto.Upload.Item"); f("method","upload"); f("version","8")
            f("uploadDestination","\"timeline\""); f("duplicate","\"ignore\"")
            f("name","\"\(filename)\""); f("mtime",mtime); f("folder","[\"PhotoLibrary\"]")
            body.append("--\(b)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append(jpeg); body.append("\r\n--\(b)--\r\n".data(using: .utf8)!)
            return ("multipart/form-data; boundary=\(b)", body)
        }) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }()
    guard let d = up?["data"] as? [String: Any], let id = d["id"] as? Int ?? d["item_id"] as? Int else {
        print("upload failed: \(up ?? [:])"); return
    }
    print("\n── test id=\(id)")
    func readState() async -> String {
        let r = await raw("SYNO.Foto.Browse.Item", "get", [
            URLQueryItem(name: "id", value: "[\(id)]"),
            URLQueryItem(name: "additional", value: "[\"favorite\",\"rating\"]")])
        let it = ((r?["data"] as? [String: Any])?["list"] as? [[String: Any]])?.first
        let add = it?["additional"] as? [String: Any]
        return "favorite=\(it?["favorite"] ?? add?["favorite"] ?? "?") rating=\(it?["rating"] ?? add?["rating"] ?? "?")"
    }
    print("   before: \(await readState())")
    let fav = await raw("SYNO.Foto.Browse.Item", "set_favorite", [URLQueryItem(name: "id", value: "[\(id)]"), URLQueryItem(name: "favorite", value: "true")])
    print("   set_favorite: success=\((fav?["success"] as? Bool) == true) → \(await readState())")
    // Rating variants (base set id=[..] rating=4 returned success but didn't stick).
    let ratingAttempts: [(String, [URLQueryItem])] = [
        ("id-array rating", [URLQueryItem(name: "id", value: "[\(id)]"), URLQueryItem(name: "rating", value: "4")]),
        ("id-scalar rating", [URLQueryItem(name: "id", value: "\(id)"), URLQueryItem(name: "rating", value: "4")]),
        ("id-array rating-array", [URLQueryItem(name: "id", value: "[\(id)]"), URLQueryItem(name: "rating", value: "[4]")]),
    ]
    for (label, q) in ratingAttempts {
        let r = await rawV("SYNO.Foto.Browse.Item", "set", 1, q)
        let s = await readState()
        print("   set rating [\(label)]: success=\((r?["success"] as? Bool) == true) → \(s)")
        if s.contains("rating=4") { print("   ✅ rating via: \(label)"); break }
    }

    // Does favorite/rating surface in LIST (not just get)? Needed for grid badges.
    let lr = await raw("SYNO.Foto.Browse.Item", "list", [
        URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "80"),
        URLQueryItem(name: "additional", value: "[\"favorite\",\"rating\"]")])
    if let row = ((lr?["data"] as? [String: Any])?["list"] as? [[String: Any]])?.first(where: { ($0["id"] as? Int) == id }) {
        let add = row["additional"] as? [String: Any]
        print("   in LIST: favorite=\(row["favorite"] ?? add?["favorite"] ?? "absent") rating=\(row["rating"] ?? add?["rating"] ?? "absent") addKeys=\(add?.keys.sorted() ?? [])")
    } else { print("   (test item not in first list page)") }

    let del = await raw("SYNO.Foto.Browse.Item", "delete", [URLQueryItem(name: "id", value: "[\(id)]")])
    print("── cleaned up: \((del?["success"] as? Bool) == true ? "✓" : "⚠️ MANUAL \(filename)")")
}

// MARK: - API coverage audit: do reference features exist on THIS NAS?

func apiAudit() async {
    let candidates = [
        "SYNO.Foto.Favorite", "SYNO.Foto.Browse.RecentlyAdded",
        "SYNO.Foto.Browse.GeneralTag", "SYNO.Foto.Browse.Category",
        "SYNO.Foto.Browse.Concept", "SYNO.Foto.Browse.ConditionAlbum",
        "SYNO.Foto.UserInfo", "SYNO.Foto.Index",
    ]
    // Discover them (adds to apiInfoMap) then report availability + version.
    try? await client.discoverAPIs(candidates, required: [], forceRefresh: true)
    print("── availability on this NAS:")
    for api in candidates {
        let info = client.endpoint(for: api)
        print("   \(api): \(info != nil ? "present (maxV \(info!.maxVersion))" : "ABSENT")")
    }

    print("\n── safe reads:")
    // Favorites: list + set_favorite existence (fake id, no mutation on real).
    let fav = await rawV("SYNO.Foto.Browse.Item", "set_favorite", 1, [
        URLQueryItem(name: "id", value: "[999999991]"), URLQueryItem(name: "favorite", value: "true")])
    print("   Item.set_favorite(fake id): success=\((fav?["success"] as? Bool) == true) err=\(((fav?["error"] as? [String:Any])?["code"]).map{"\($0)"} ?? "-")")
    let rating = await rawV("SYNO.Foto.Browse.Item", "set", 1, [
        URLQueryItem(name: "id", value: "[999999991]"), URLQueryItem(name: "rating", value: "3")])
    print("   Item.set(rating, fake id): success=\((rating?["success"] as? Bool) == true) err=\(((rating?["error"] as? [String:Any])?["code"]).map{"\($0)"} ?? "-")")

    for (api, m, extra) in [
        ("SYNO.Foto.Browse.GeneralTag", "list", [URLQueryItem(name:"offset",value:"0"),URLQueryItem(name:"limit",value:"20")]),
        ("SYNO.Foto.Browse.Category", "get", []),
        ("SYNO.Foto.Browse.Concept", "list", [URLQueryItem(name:"offset",value:"0"),URLQueryItem(name:"limit",value:"20")]),
        ("SYNO.Foto.Browse.RecentlyAdded", "list", [URLQueryItem(name:"offset",value:"0"),URLQueryItem(name:"limit",value:"20")]),
        ("SYNO.Foto.UserInfo", "me", []),
        ("SYNO.Foto.Index", "get", []),
    ] {
        let r = await rawV(api, m, 1, extra)
        let ok = (r?["success"] as? Bool) == true
        let code = ((r?["error"] as? [String:Any])?["code"]).map{"\($0)"} ?? "-"
        var detail = ""
        if ok, let data = r?["data"] as? [String: Any] {
            detail = "keys=\(data.keys.sorted())"
            if let list = data["list"] as? [[String: Any]] { detail += " count=\(list.count)" + (list.first.map { " sample=\($0.keys.sorted().prefix(8))" } ?? "") }
        }
        print("   \(api) \(m): success=\(ok) err=\(code) \(detail)")
    }
}

// MARK: - Edit taken-date: probe SET method on a TEST upload, then clean up

func dateEditProbe() async {
    // 0) Method existence with a fake id (safe).
    print("── set-time method probes (fake id):")
    for (m, key) in [("set", "time"), ("set", "taken_time"), ("set_taken_time", "time"), ("edit", "time")] {
        let r = await raw("SYNO.Foto.Browse.Item", m, [URLQueryItem(name: "id", value: "[999999991]"), URLQueryItem(name: key, value: "1600000000")])
        let code = ((r?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
        if code != "103" { print("   Item.\(m)(\(key)): EXISTS (err \(code))") }
    }

    // 1) Upload a synthetic test photo we own.
    let filename = "SYNOPHOTOS_DATETEST_\(UUID().uuidString.prefix(8)).jpg"
    let jpeg = makeTestJPEG()
    let mtime = String(Int(Date().timeIntervalSince1970 * 1000))
    let uploadResp: [String: Any]? = await {
        guard let data = try? await client.requestMultipart(api: "SYNO.Foto.Upload.Item", extraQuery: [
            URLQueryItem(name: "api", value: "SYNO.Foto.Upload.Item"),
            URLQueryItem(name: "method", value: "upload"), URLQueryItem(name: "version", value: "8"),
        ], pathSuffix: "SYNO.Foto.Upload.Item", build: { _, _ in
            let boundary = "----writespike\(UUID().uuidString)"
            var body = Data()
            func field(_ name: String, _ value: String) {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
                body.append("\(value)\r\n".data(using: .utf8)!)
            }
            field("api", "SYNO.Foto.Upload.Item"); field("method", "upload"); field("version", "8")
            field("uploadDestination", "\"timeline\""); field("duplicate", "\"ignore\"")
            field("name", "\"\(filename)\""); field("mtime", mtime); field("folder", "[\"PhotoLibrary\"]")
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append(jpeg); body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
            return ("multipart/form-data; boundary=\(boundary)", body)
        }) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }()
    guard let d = uploadResp?["data"] as? [String: Any],
          let newId = d["id"] as? Int ?? d["item_id"] as? Int else {
        print("   upload failed: \(uploadResp ?? [:])"); return
    }
    print("\n── uploaded test id=\(newId) '\(filename)'")

    func currentTime() async -> Int? {
        let r = await raw("SYNO.Foto.Browse.Item", "get", [URLQueryItem(name: "id", value: "[\(newId)]")])
        return ((((r?["data"] as? [String: Any])?["list"] as? [[String: Any]])?.first)?["time"] as? Int)
    }
    let before = await currentTime()
    let target = 1_262_304_000   // 2010-01-01 UTC — clearly different
    print("   time BEFORE: \(before.map(String.init) ?? "?")")

    // 2) Try candidate SET shapes until the time actually changes.
    let attempts: [(String, [URLQueryItem])] = [
        ("set time",           [URLQueryItem(name: "id", value: "[\(newId)]"), URLQueryItem(name: "time", value: "\(target)")]),
        ("set taken_time",     [URLQueryItem(name: "id", value: "[\(newId)]"), URLQueryItem(name: "taken_time", value: "\(target)")]),
        ("set id-scalar time", [URLQueryItem(name: "id", value: "\(newId)"),   URLQueryItem(name: "time", value: "\(target)")]),
    ]
    var worked = false
    for (label, q) in attempts {
        let r = await raw("SYNO.Foto.Browse.Item", "set", q)
        let ok = (r?["success"] as? Bool) == true
        let code = ((r?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
        let now = await currentTime()
        print("   [\(label)] success=\(ok) err=\(code) → time=\(now.map(String.init) ?? "?")")
        if now == target { print("   ✅ taken-date edit works via: \(label)"); worked = true; break }
    }
    if !worked { print("   ⚠️ no shape changed the time") }

    // 3) Clean up the test upload.
    let del = await raw("SYNO.Foto.Browse.Item", "delete", [URLQueryItem(name: "id", value: "[\(newId)]")])
    print("── cleaned up test upload: \((del?["success"] as? Bool) == true ? "✓" : "⚠️ MANUAL DELETE \(filename)")")
}

// MARK: - Duplicate detection: native API? + real client-side dup census

func dupeProbe() async {
    // 1) Does the NAS expose a native duplicate/similar grouping API?
    print("── native API availability:")
    for api in ["SYNO.Foto.Browse.SimilarItem", "SYNO.Foto.Browse.SimilarTimeline",
                "SYNO.Foto.Browse.RecentlyAdded", "SYNO.Foto.Search.Search"] {
        let info = client.endpoint(for: api)
        print("   \(api): \(info != nil ? "present (maxV \(info!.maxVersion))" : "ABSENT")")
    }
    print("── SimilarItem/SimilarTimeline method probes (non-103 = exists):")
    for (api, m, v) in [("SYNO.Foto.Browse.SimilarItem", "list", 1), ("SYNO.Foto.Browse.SimilarItem", "get", 1),
                        ("SYNO.Foto.Browse.SimilarItem", "list_group", 1), ("SYNO.Foto.Browse.SimilarTimeline", "list", 1),
                        ("SYNO.Foto.Browse.SimilarTimeline", "get", 1)] {
        let r = await rawV(api, m, v, [URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "10")])
        let ok = (r?["success"] as? Bool) == true
        let code = ((r?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
        print("   \(api) \(m): success=\(ok) err=\(code)" + (ok ? " keys=\((( r?["data"] as? [String: Any])?.keys.sorted()) ?? [])" : ""))
    }

    // 2) Client-side census over ALL items (the approach we'll actually ship).
    print("\n── client-side duplicate census (all items):")
    struct Row { let id: Int; let name: String; let size: Int; let time: Int; let folder: Int; let res: String }
    var rows: [Row] = []
    var offset = 0
    while true {
        guard let r = await raw("SYNO.Foto.Browse.Item", "list", [
            URLQueryItem(name: "offset", value: "\(offset)"), URLQueryItem(name: "limit", value: "1000"),
            URLQueryItem(name: "sort_by", value: "takentime"), URLQueryItem(name: "sort_direction", value: "desc"),
            URLQueryItem(name: "additional", value: "[\"resolution\"]"),
        ]), let list = ((r["data"] as? [String: Any])?["list"] as? [[String: Any]]), !list.isEmpty else { break }
        for it in list {
            let add = it["additional"] as? [String: Any]
            let res = (add?["resolution"] as? [String: Any]).map { "\($0["width"] ?? 0)x\($0["height"] ?? 0)" } ?? "?"
            rows.append(Row(id: it["id"] as? Int ?? 0, name: it["filename"] as? String ?? "?",
                            size: it["filesize"] as? Int ?? 0, time: it["time"] as? Int ?? 0,
                            folder: it["folder_id"] as? Int ?? 0, res: res))
        }
        offset += list.count
        if list.count < 1000 { break }
    }
    print("   total items: \(rows.count)")

    func report(_ label: String, _ key: (Row) -> String) {
        let groups = Dictionary(grouping: rows, by: key).filter { $0.value.count > 1 }
        let extra = groups.values.reduce(0) { $0 + $1.count - 1 }
        let bytes = groups.values.reduce(0) { acc, g in acc + g.dropFirst().reduce(0) { $0 + $1.size } }
        print("   [\(label)] \(groups.count) groups, \(extra) removable copies, ~\(bytes / 1_048_576) MB reclaimable")
        for (k, g) in groups.sorted(by: { $0.value.count > $1.value.count }).prefix(3) {
            print("      e.g. \(g.count)×  \(g[0].name)  \(g[0].size)B  [\(k)]  ids=\(g.map(\.id).prefix(4))")
        }
    }
    report("name+size") { "\($0.name)|\($0.size)" }
    report("size+time+res") { "\($0.size)|\($0.time)|\($0.res)" }
    report("size only") { "\($0.size)" }

    // 3) Native "similar" grouping structure (Synology's own 유사 항목 review).
    print("\n── native SimilarTimeline.get (section) structure:")
    if let r = await rawV("SYNO.Foto.Browse.SimilarTimeline", "get", 2, []),
       let data = r["data"] as? [String: Any], let sections = data["section"] as? [[String: Any]] {
        print("   sections: \(sections.count)  (each = one similar group)")
        var groupSizes: [Int] = []
        for s in sections {
            let list = (s["list"] as? [[String: Any]]) ?? []
            groupSizes.append(list.count)
        }
        print("   group sizes: \(groupSizes)  total members=\(groupSizes.reduce(0,+))  removable(keep-1)=\(groupSizes.reduce(0){$0+max(0,$1-1)})")
        if let s = sections.first, let list = s["list"] as? [[String: Any]], let m = list.first {
            print("   member keys=\(m.keys.sorted())")
            print("   sample group[0]: " + list.prefix(6).map { "\($0["id"] ?? "?"):\(($0["filename"] as? String) ?? "?")" }.joined(separator: ", "))
        }
    } else { print("   (no data)") }

    print("── native SimilarItem.list — full item structure + grouping field:")
    if let r = await rawV("SYNO.Foto.Browse.SimilarItem", "list", 2, [
        URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "60"),
        URLQueryItem(name: "additional", value: "[\"thumbnail\"]"),
        URLQueryItem(name: "sort_by", value: "takentime"), URLQueryItem(name: "sort_direction", value: "desc"),
    ]), let list = ((r["data"] as? [String: Any])?["list"] as? [[String: Any]]) {
        print("   returned \(list.count) items; keys=\((list.first?.keys.sorted()) ?? [])")
        // Look for any field that clusters items into similar-groups.
        let candidateKeys = Set(list.flatMap { $0.keys }).subtracting(["id","filename","filesize","folder_id","owner_user_id","time","indexed_time","type","additional"])
        print("   extra (grouping?) keys present: \(candidateKeys.sorted())")
        for k in candidateKeys.sorted() {
            let vals = list.compactMap { $0[k].map { "\($0)" } }
            let distinct = Set(vals)
            print("      \(k): \(distinct.count) distinct over \(vals.count) items  e.g. \(Array(distinct).prefix(5))")
        }
        // Show first items with their time so we can see clustering by time.
        print("   first items (id/time/name):")
        for it in list.prefix(12) {
            print("      \(it["id"] ?? "?")  t=\(it["time"] ?? "?")  \(( it["filename"] as? String) ?? "?")")
        }
    } else { print("   (no data)") }

    // 4) Full paging: collect every similar group, verify members resolve.
    print("\n── full SimilarItem paging:")
    var all: [Int: [String: Any]] = [:]   // id → item
    var groups: [[String: Any]] = []
    var off = 0
    while true {
        guard let r = await rawV("SYNO.Foto.Browse.SimilarItem", "list", 2, [
            URLQueryItem(name: "offset", value: "\(off)"), URLQueryItem(name: "limit", value: "500"),
            URLQueryItem(name: "additional", value: "[\"thumbnail\"]"),
        ]), let list = ((r["data"] as? [String: Any])?["list"] as? [[String: Any]]), !list.isEmpty else { break }
        for it in list {
            if let id = it["id"] as? Int { all[id] = it }
            if let sim = it["similar"] as? [String: Any] { groups.append(sim) }
        }
        off += list.count
        if list.count < 500 { break }
    }
    let removable = groups.reduce(0) { $0 + max(0, ($1["count"] as? Int ?? 1) - 1) }
    let unresolved = groups.flatMap { ($0["item_id"] as? [Int]) ?? [] }.filter { all[$0] == nil }
    let topPicksInList = groups.allSatisfy { g in (g["top_pick"] as? Int).map { all[$0] != nil } ?? false }
    print("   total similar items returned: \(all.count)")
    print("   similar groups: \(groups.count)  removable(keep top_pick)=\(removable)")
    print("   member ids unresolved in list: \(unresolved.count)  \(unresolved.prefix(10))")
    print("   every top_pick present in list: \(topPicksInList)")
    print("   group sizes: \(groups.compactMap { $0["count"] as? Int }.sorted(by: >))")
}

// MARK: - Album rename: find the method, verify on a TEST album, clean up

func albumRenameProbe() async {
    // 1) Method existence with a fake id (safe).
    print("── method existence (fake id):")
    for (api, m) in [("SYNO.Foto.Browse.NormalAlbum", "set_name"), ("SYNO.Foto.Browse.NormalAlbum", "rename"),
                     ("SYNO.Foto.Browse.NormalAlbum", "set"), ("SYNO.Foto.Browse.NormalAlbum", "edit"),
                     ("SYNO.Foto.Browse.Album", "set_name"), ("SYNO.Foto.Browse.Album", "rename"),
                     ("SYNO.Foto.Browse.Album", "set"), ("SYNO.Foto.Browse.Album", "set_condition")] {
        let r = await raw(api, m, [URLQueryItem(name: "id", value: "999999991"), URLQueryItem(name: "name", value: "\"x\"")])
        let code = ((r?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
        if code != "103" { print("   \(api) \(m): EXISTS(err \(code))") }
    }

    // 2) Round-trip on a fresh TEST album.
    let created = await raw("SYNO.Foto.Browse.NormalAlbum", "create", [
        URLQueryItem(name: "name", value: "⚠️TEST_RENAME_A"), URLQueryItem(name: "item", value: "[]"),
    ])
    guard let albumId = ((created?["data"] as? [String: Any])?["album"] as? [String: Any])?["id"] as? Int else {
        print("create failed"); return
    }
    func nameNow() async -> String {
        let l = await raw("SYNO.Foto.Browse.Album", "list", [URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "100")])
        return ((((l?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []).first { ($0["id"] as? Int) == albumId }?["name"] as? String) ?? "?"
    }
    print("test album id=\(albumId) name=\(await nameNow())")
    // Try shapes on whichever method existed (set_name most likely).
    for (api, m, q) in [
        ("SYNO.Foto.Browse.NormalAlbum", "set_name", [URLQueryItem(name: "id", value: "\(albumId)"), URLQueryItem(name: "name", value: "\"⚠️TEST_RENAME_B\"")]),
        ("SYNO.Foto.Browse.NormalAlbum", "set_name", [URLQueryItem(name: "id", value: "\(albumId)"), URLQueryItem(name: "name", value: "⚠️TEST_RENAME_B")]),
        ("SYNO.Foto.Browse.Album", "set_name", [URLQueryItem(name: "id", value: "\(albumId)"), URLQueryItem(name: "name", value: "\"⚠️TEST_RENAME_B\"")]),
    ] {
        let r = await raw(api, m, q)
        let ok = (r?["success"] as? Bool) == true
        let code = ((r?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
        let now = await nameNow()
        print("   \(api) \(m) [\(q[1].value ?? "")]: success=\(ok) err=\(code) → name=\(now)")
        if now.contains("RENAME_B") { print("   ✅ rename works"); break }
    }
    _ = await raw("SYNO.Foto.Browse.Album", "delete", [URLQueryItem(name: "id", value: "[\(albumId)]")])
    print("cleaned up")
}

// MARK: - Where do shared (temporary_shared) albums show up?

func shareVisibility() async {
    try? await client.discoverAPIs(writeAPIs + ["SYNO.FotoTeam.Browse.Album"], required: [], forceRefresh: true)
    // Grab one real item to put in the shared album.
    let items = await raw("SYNO.Foto.Browse.Item", "list", [URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "1")])
    let itemId = ((items?["data"] as? [String: Any])?["list"] as? [[String: Any]])?.first?["id"] as? Int ?? -1
    let created = await raw("SYNO.Foto.Browse.NormalAlbum", "create", [
        URLQueryItem(name: "name", value: "⚠️TEST_SHARE_VIS"), URLQueryItem(name: "item", value: "[\(itemId)]"),
        URLQueryItem(name: "shared", value: "true"),
    ])
    guard let albumId = ((created?["data"] as? [String: Any])?["album"] as? [String: Any])?["id"] as? Int else { print("create failed"); return }
    print("shared album id=\(albumId) (1 item)")

    func listAlbums(_ api: String) async -> [(Int, String, Bool)] {
        let r = await raw(api, "list", [URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "100")])
        return (((r?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []).map {
            ($0["id"] as? Int ?? -1, $0["name"] as? String ?? "", ($0["temporary_shared"] as? Bool) ?? false)
        }
    }
    let personal = await listAlbums("SYNO.Foto.Browse.Album")
    let team = await listAlbums("SYNO.FotoTeam.Browse.Album")
    print("personal albums: \(personal.map { "\($0.0):\($0.1)\($0.2 ? "(temp_shared)" : "")" })")
    print("  → our album in personal: \(personal.contains { $0.0 == albumId })")
    print("team albums: \(team.map { "\($0.0):\($0.1)\($0.2 ? "(temp_shared)" : "")" })")
    print("  → our album in team: \(team.contains { $0.0 == albumId })")

    _ = await raw("SYNO.Foto.Browse.Album", "delete", [URLQueryItem(name: "id", value: "[\(albumId)]")])
    print("cleaned up")
}

// MARK: - Which sharing APIs exist + their create/enable methods?

func shareApisProbe() async {
    let candidates = [
        "SYNO.Foto.Sharing.Passphrase", "SYNO.Foto.Sharing.Misc", "SYNO.Foto.Sharing.NormalAlbum",
        "SYNO.Foto.Sharing.Sharee", "SYNO.Foto.Sharing.FolderAlbum", "SYNO.Foto.Sharing.SmartAlbum",
        "SYNO.Foto.Sharing.Category", "SYNO.Foto.Sharing.Item", "SYNO.Foto.Sharing.Setting",
    ]
    try? await client.discoverAPIs(writeAPIs + candidates, required: [], forceRefresh: true)
    // An API that resolved is one whose `endpoint(for:)` is non-nil.
    let existing = candidates.filter { client.endpoint(for: $0) != nil }
    print("existing sharing APIs: \(existing)")

    // Probe create/enable methods on each existing sharing API.
    let methods = ["create", "update", "set", "get", "enable", "share", "add", "set_privacy",
                   "get_privacy", "set_share_setting", "get_share_setting", "list", "list_user_group", "confirm"]
    for api in existing {
        print("\n── \(api):")
        for m in methods {
            let r = await raw(api, m, [])
            let code = ((r?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
            let ok = (r?["success"] as? Bool) == true
            if code != "103" { print("   \(m): \(ok ? "✓ SUCCESS" : "EXISTS(err \(code))")") }
        }
    }
}

// MARK: - Safe end-to-end share test on a TEST album (created + deleted)

func shareTest() async {
    func jstr(_ v: Any?, _ n: Int = 900) -> String {
        guard let v, let d = try? JSONSerialization.data(withJSONObject: v), let s = String(data: d, encoding: .utf8) else { return "\(v ?? "nil")" }
        return String(s.prefix(n))
    }
    try? await client.discoverAPIs(writeAPIs + ["SYNO.Foto.Sharing.Passphrase", "SYNO.Foto.Sharing.Misc"], required: [], forceRefresh: true)
    await shareRoundTrip(jstr)
}

/// Full share round-trip on a TEST album: create(shared)→enable→link→disable→delete.
func shareRoundTrip(_ jstr: @escaping (Any?, Int) -> String) async {
    // Share state lives in the album's sharing_info additional.
    func sharingInfo(_ albumId: Int) async -> [String: Any]? {
        let list = await raw("SYNO.Foto.Browse.Album", "list", [
            URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "additional", value: "[\"sharing_info\"]"),
        ])
        let a = (((list?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []).first { ($0["id"] as? Int) == albumId }
        return (a?["additional"] as? [String: Any])?["sharing_info"] as? [String: Any]
    }
    func getShare(_ albumId: Int) async -> [String: Any]? { await sharingInfo(albumId) }
    // 1) Create album WITH shared=true → mints a passphrase (sharing still private).
    let created = await raw("SYNO.Foto.Browse.NormalAlbum", "create", [
        URLQueryItem(name: "name", value: "⚠️TEST_DELETE_\(UUID().uuidString.prefix(6))"),
        URLQueryItem(name: "item", value: "[]"), URLQueryItem(name: "shared", value: "true"),
    ])
    guard let alb = (created?["data"] as? [String: Any])?["album"] as? [String: Any],
          let albumId = alb["id"] as? Int, let pp = alb["passphrase"] as? String, !pp.isEmpty else {
        print("create(shared) failed: \(jstr(created, 300))"); return
    }
    print("✓ album id=\(albumId) passphrase=\(pp)")
    print("  create album full: \(jstr(alb, 700))")

    // 2) Enable public view.
    let up = await raw("SYNO.Foto.Sharing.Passphrase", "update", [
        URLQueryItem(name: "passphrase", value: "\"\(pp)\""),
        URLQueryItem(name: "expiration", value: "0"),
        URLQueryItem(name: "permission", value: "[{\"action\":\"update\",\"role\":\"view\",\"member\":{\"type\":\"public\"}}]"),
    ])
    print("  enable update: success=\((up?["success"] as? Bool) == true) data=\(jstr(up?["data"], 400))")
    // Where is the share state? Try all sources.
    let pg = await raw("SYNO.Foto.Sharing.Passphrase", "get", [URLQueryItem(name: "passphrase", value: "\"\(pp)\"")])
    print("  Passphrase.get: \(jstr(pg?["data"], 600))")
    let ag = await raw("SYNO.Foto.Browse.Album", "get", [URLQueryItem(name: "id", value: "[\(albumId)]"), URLQueryItem(name: "additional", value: "[\"sharing_info\"]")])
    print("  Album.get: \(jstr(ag?["data"], 700))")
    let lst = await raw("SYNO.Foto.Browse.Album", "list", [URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "additional", value: "[\"sharing_info\"]")])
    let albums = ((lst?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
    print("  Album.list: \(albums.count) albums, ids=\(albums.compactMap { $0["id"] as? Int })")
    let shared = albums.first { ($0["id"] as? Int) == albumId }.flatMap { ($0["additional"] as? [String: Any])?["sharing_info"] as? [String: Any] }
    print("  → sharing_link: \(shared?["sharing_link"] ?? "nil")")

    // How are shared albums listed? Try category/type params.
    for extra in [[URLQueryItem(name: "category", value: "shared_with_me")],
                  [URLQueryItem(name: "category", value: "shared_by_me")],
                  [URLQueryItem(name: "category", value: "shared")],
                  [URLQueryItem(name: "additional", value: "[\"sharing_info\"]"), URLQueryItem(name: "category", value: "normal_share")]] {
        let l = await raw("SYNO.Foto.Browse.Album", "list", [URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "50")] + extra)
        let ids = (((l?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? Int }
        let code = ((l?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
        print("  list \(extra.map { "\($0.name)=\($0.value ?? "")" }): err=\(code) ids=\(ids) hasOurs=\(ids.contains(albumId))")
    }

    // 3) Disable (unshare) — try several mechanisms; check privacy_type.
    func privacyNow() async -> String {
        let g = await raw("SYNO.Foto.Browse.Album", "get", [URLQueryItem(name: "id", value: "[\(albumId)]"), URLQueryItem(name: "additional", value: "[\"sharing_info\"]")])
        let si = (((g?["data"] as? [String: Any])?["list"] as? [[String: Any]])?.first?["additional"] as? [String: Any])?["sharing_info"] as? [String: Any]
        return (si?["privacy_type"] as? String) ?? "?"
    }
    let disableAttempts: [(String, [URLQueryItem])] = [
        ("perm delete", [URLQueryItem(name: "passphrase", value: "\"\(pp)\""), URLQueryItem(name: "expiration", value: "0"), URLQueryItem(name: "permission", value: "[{\"action\":\"delete\",\"role\":\"view\",\"member\":{\"type\":\"public\"}}]")]),
        ("privacy private", [URLQueryItem(name: "passphrase", value: "\"\(pp)\""), URLQueryItem(name: "privacy_type", value: "\"private\"")]),
        ("perm empty+priv", [URLQueryItem(name: "passphrase", value: "\"\(pp)\""), URLQueryItem(name: "expiration", value: "0"), URLQueryItem(name: "permission", value: "[]"), URLQueryItem(name: "privacy_type", value: "\"private\"")]),
    ]
    for (label, q) in disableAttempts {
        let un = await raw("SYNO.Foto.Sharing.Passphrase", "update", q)
        let ok = (un?["success"] as? Bool) == true
        let code = ((un?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
        print("  disable '\(label)': success=\(ok) err=\(code) → privacy=\(await privacyNow())")
        if ok { break }
    }

    // 4) Cleanup.
    let del = await raw("SYNO.Foto.Browse.Album", "delete", [URLQueryItem(name: "id", value: "[\(albumId)]")])
    print("✓ deleted: \((del?["success"] as? Bool) == true)")
}

func shareTestOld() async {
    func jstr(_ v: Any?, _ n: Int = 900) -> String {
        guard let v, let d = try? JSONSerialization.data(withJSONObject: v), let s = String(data: d, encoding: .utf8) else { return "\(v ?? "nil")" }
        return String(s.prefix(n))
    }
    try? await client.discoverAPIs(writeAPIs + ["SYNO.Foto.Sharing.Passphrase", "SYNO.Foto.Sharing.Misc"], required: [], forceRefresh: true)

    // 1) Create an empty test album.
    let name = "⚠️TEST_DELETE_\(UUID().uuidString.prefix(6))"
    let created = await raw("SYNO.Foto.Browse.NormalAlbum", "create", [
        URLQueryItem(name: "name", value: name), URLQueryItem(name: "item", value: "[]"),
    ])
    guard let albumId = ((created?["data"] as? [String: Any])?["album"] as? [String: Any])?["id"] as? Int else {
        print("create failed: \(jstr(created))"); return
    }
    let createdAlbum = (created?["data"] as? [String: Any])?["album"] as? [String: Any] ?? [:]
    print("✓ test album id=\(albumId)")
    print("  create response album keys: \(createdAlbum.keys.sorted())")
    print("  passphrase in create: \(createdAlbum["passphrase"] ?? "nil")")

    // 2) Find passphrase via Browse.Album list (with sharing_info).
    var passphrase = createdAlbum["passphrase"] as? String ?? ""
    if passphrase.isEmpty {
        let list = await raw("SYNO.Foto.Browse.Album", "list", [
            URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "additional", value: "[\"sharing_info\"]"),
        ])
        if let a = (((list?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []).first(where: { ($0["id"] as? Int) == albumId }) {
            print("  album(list) keys: \(a.keys.sorted())")
            passphrase = a["passphrase"] as? String ?? ""
            print("  passphrase(list): '\(passphrase)'  sharing_info=\(jstr(a["additional"], 300))")
        }
    }

    // 3) Share. Passphrase is empty pre-share → try update with the album id
    //    (server should create + return a passphrase). Probe a few param names.
    let pub = "[{\"action\":\"update\",\"role\":\"view\",\"member\":{\"type\":\"public\"}}]"
    let exp = URLQueryItem(name: "expiration", value: "0")
    let perm = URLQueryItem(name: "permission", value: pub)
    let attempts: [(String, [URLQueryItem])] = [
        ("target=[{album}]", [exp, perm, URLQueryItem(name: "target", value: "[{\"type\":\"album\",\"id\":\(albumId)}]")]),
        ("target={album}", [exp, perm, URLQueryItem(name: "target", value: "{\"type\":\"album\",\"id\":\(albumId)}")]),
        ("target_id+type", [exp, perm, URLQueryItem(name: "target_id", value: "\(albumId)"), URLQueryItem(name: "type", value: "\"album\"")]),
        ("album=[id]", [exp, perm, URLQueryItem(name: "album", value: "[\(albumId)]")]),
        ("id+type=album", [exp, perm, URLQueryItem(name: "id", value: "\(albumId)"), URLQueryItem(name: "type", value: "\"album\"")]),
        ("passphrase=''+target", [exp, perm, URLQueryItem(name: "passphrase", value: "\"\""), URLQueryItem(name: "target", value: "[{\"type\":\"album\",\"id\":\(albumId)}]")]),
    ]
    for (label, q) in attempts {
        let up = await raw("SYNO.Foto.Sharing.Passphrase", "update", q)
        let ok = (up?["success"] as? Bool) == true
        let code = ((up?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
        print("update \(label): success=\(ok) err=\(code) data=\(jstr(up?["data"], 300))")
        if ok, let d = up?["data"] as? [String: Any] {
            let pp = (d["passphrase"] as? String) ?? ((d["share"] as? [String: Any])?["passphrase"] as? String)
                ?? (((d["list"] as? [[String: Any]])?.first)?["passphrase"] as? String)
            if let pp, !pp.isEmpty { passphrase = pp; print("  ✓ created passphrase=\(pp)"); break }
        }
    }
    // Probe NormalAlbum + Passphrase for a passphrase-CREATING method.
    if passphrase.isEmpty {
        print("── hunting passphrase-create method (album \(albumId)):")
        for (api, m) in [("SYNO.Foto.Browse.NormalAlbum", "share"), ("SYNO.Foto.Browse.NormalAlbum", "set_shared"),
                         ("SYNO.Foto.Browse.NormalAlbum", "set_condition"), ("SYNO.Foto.Browse.NormalAlbum", "update"),
                         ("SYNO.Foto.Browse.NormalAlbum", "set_passphrase"), ("SYNO.Foto.Browse.Album", "update"),
                         ("SYNO.Foto.Browse.Album", "share")] {
            let r = await raw(api, m, [URLQueryItem(name: "id", value: "\(albumId)")])
            let code = ((r?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
            print("   \(api) \(m): \(code == "103" ? "absent" : "EXISTS(err \(code))")")
        }
        // get-or-create? Passphrase.get with an album id.
        for k in ["id", "album_id", "passphrase"] {
            let g = await raw("SYNO.Foto.Sharing.Passphrase", "get", [URLQueryItem(name: k, value: k == "passphrase" ? "\"\"" : "\(albumId)")])
            let code = ((g?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
            let pp = ((g?["data"] as? [String: Any])?["passphrase"] as? String)
            print("   get \(k)=\(albumId): err=\(code) passphrase=\(pp ?? "nil") data=\(jstr(g?["data"], 200))")
            if let pp, !pp.isEmpty { passphrase = pp }
        }
        // update with permission member referencing the album as sharee target.
        for permWithTarget in [
            "[{\"action\":\"update\",\"role\":\"view\",\"member\":{\"type\":\"public\"}}]",
        ] {
            let up = await raw("SYNO.Foto.Sharing.Passphrase", "update", [
                URLQueryItem(name: "album_id", value: "\(albumId)"),
                URLQueryItem(name: "passphrase", value: "\"\""),
                URLQueryItem(name: "expiration", value: "0"),
                URLQueryItem(name: "permission", value: permWithTarget),
            ])
            print("   update album_id+passphrase='': err=\(((up?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-")")
        }
        // Create a NEW album WITH a share flag → does it mint a passphrase?
        for extra in [[URLQueryItem(name: "shared", value: "true")],
                      [URLQueryItem(name: "type", value: "\"shared\"")]] {
            let c = await raw("SYNO.Foto.Browse.NormalAlbum", "create",
                              [URLQueryItem(name: "name", value: "⚠️TEST2_\(UUID().uuidString.prefix(4))"), URLQueryItem(name: "item", value: "[]")] + extra)
            let alb = (c?["data"] as? [String: Any])?["album"] as? [String: Any]
            let pp = alb?["passphrase"] as? String
            print("   create +\(extra.map(\.name)): err=\(((c?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-") passphrase=\(pp ?? "nil")")
            if let aid = alb?["id"] as? Int { _ = await raw("SYNO.Foto.Browse.Album", "delete", [URLQueryItem(name: "id", value: "[\(aid)]")]) }
        }
    }
    // Re-read the album's passphrase in case update populated it.
    if passphrase.isEmpty {
        let list = await raw("SYNO.Foto.Browse.Album", "list", [
            URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "additional", value: "[\"sharing_info\"]"),
        ])
        if let a = (((list?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []).first(where: { ($0["id"] as? Int) == albumId }) {
            passphrase = a["passphrase"] as? String ?? ""
            print("album passphrase after update: '\(passphrase)' sharing_info=\(jstr((a["additional"] as? [String: Any])?["sharing_info"], 300))")
        }
    }

    if !passphrase.isEmpty {
        // 4) get to verify.
        let g = await raw("SYNO.Foto.Sharing.Passphrase", "get", [URLQueryItem(name: "passphrase", value: "\"\(passphrase)\"")])
        print("get after share: \(jstr(g?["data"], 500))")
        print("→ share link: https://<nas-host>:5001/photo/mo/sharing/\(passphrase)")
        // 5) Unshare candidates.
        for perm in ["[]", "[{\"action\":\"delete\",\"role\":\"view\",\"member\":{\"type\":\"public\"}}]"] {
            let un = await raw("SYNO.Foto.Sharing.Passphrase", "update", [
                URLQueryItem(name: "passphrase", value: "\"\(passphrase)\""),
                URLQueryItem(name: "expiration", value: "0"),
                URLQueryItem(name: "permission", value: perm),
            ])
            let g2 = await raw("SYNO.Foto.Sharing.Passphrase", "get", [URLQueryItem(name: "passphrase", value: "\"\(passphrase)\"")])
            print("unshare perm=\(perm.prefix(12)): success=\((un?["success"] as? Bool) == true) → get=\(jstr(g2?["data"], 200))")
        }
    }

    // 6) Cleanup: delete the test album (also removes its share).
    let del = await raw("SYNO.Foto.Browse.Album", "delete", [URLQueryItem(name: "id", value: "[\(albumId)]")])
    print("\n✓ deleted test album: \((del?["success"] as? Bool) == true)")
}

// MARK: - Does the album object carry a passphrase? + Passphrase.get shape

func sharePassphraseProbe() async {
    func jstr(_ v: Any?, _ n: Int = 1200) -> String {
        guard let v, let d = try? JSONSerialization.data(withJSONObject: v), let s = String(data: d, encoding: .utf8) else { return "\(v ?? "nil")" }
        return String(s.prefix(n))
    }
    try? await client.discoverAPIs(writeAPIs + ["SYNO.Foto.Sharing.Passphrase"], required: [], forceRefresh: true)

    // 1) Does Browse.Album list include a passphrase per album?
    let r = await raw("SYNO.Foto.Browse.Album", "list", [
        URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "5"),
        URLQueryItem(name: "additional", value: "[\"thumbnail\",\"sharing_info\"]"),
    ])
    let albums = ((r?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
    if let a = albums.first {
        print("album keys: \(a.keys.sorted())")
        print("first album: \(jstr(a))")
        // Look for a passphrase-ish field.
        for k in a.keys where k.lowercased().contains("pass") || k.lowercased().contains("shar") {
            print("  \(k) = \(jstr(a[k], 200))")
        }
        // 2) Passphrase.get with the album's passphrase (if present).
        if let pp = a["passphrase"] as? String, !pp.isEmpty {
            let g = await raw("SYNO.Foto.Sharing.Passphrase", "get", [URLQueryItem(name: "passphrase", value: "\"\(pp)\"")])
            let code = ((g?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
            print("\nPassphrase.get passphrase=\(pp): err=\(code) data=\(jstr(g?["data"]))")
        } else {
            print("\n(no passphrase on album — check other albums / a get-or-create call)")
            for a in albums { print("  album \(a["id"] as? Int ?? -1) '\(a["name"] as? String ?? "")': passphrase=\(a["passphrase"] ?? "nil")") }
        }
    }
}

// MARK: - Explore the sharing APIs (read-only: discover + list existing shares)

func shareExplore() async {
    func jstr(_ v: Any?, _ n: Int = 1500) -> String {
        guard let v, let d = try? JSONSerialization.data(withJSONObject: v), let s = String(data: d, encoding: .utf8) else { return "\(v ?? "nil")" }
        return String(s.prefix(n))
    }
    // 1) Discover Foto sharing APIs.
    let info = await raw("SYNO.API.Info", "query", [URLQueryItem(name: "query", value: "all")])
    let all = (info?["data"] as? [String: Any])?.keys ?? Dictionary<String,Any>().keys
    let names = all.filter { $0.lowercased().contains("foto") && $0.lowercased().contains("shar") }.sorted()
    print("sharing APIs (\(names.count)):")
    for n in names {
        let i = (info?["data"] as? [String: Any])?[n] as? [String: Any]
        print("  \(n)  maxVersion=\(i?["maxVersion"] ?? "?")")
    }
    // Need these discovered to call them.
    let shareAPIs = names + ["SYNO.Foto.Sharing.Passphrase", "SYNO.Foto.Sharing.Misc", "SYNO.Foto.Sharing.NormalAlbum"]
    try? await client.discoverAPIs(Array(Set(shareAPIs)), required: [], forceRefresh: true)

    // 2) Read-only: list existing shares + share settings.
    // Method-existence probe (117 = exists/wrong-params, 103 = absent).
    for api in ["SYNO.Foto.Sharing.Passphrase", "SYNO.Foto.Sharing.Misc"] {
        print("\n── \(api) methods:")
        for m in ["list", "get", "create", "share", "set", "delete", "update", "get_setting",
                  "list_shared_with_me", "list_by_category", "confirm"] {
            let r = await raw(api, m, [])
            let code = ((r?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
            let ok = (r?["success"] as? Bool) == true
            let mark = ok ? "✓ SUCCESS" : (code == "103" ? "absent" : "EXISTS(err \(code))")
            print("   \(m): \(mark)")
            if ok, let d = r?["data"] { print("      data=\(jstr(d, 500))") }
        }
    }
}

// MARK: - What EXIF facet values exist + how to filter by them?

func exifFacetsProbe() async {
    func jstr(_ v: Any?, _ n: Int = 600) -> String {
        guard let v, let d = try? JSONSerialization.data(withJSONObject: v), let s = String(data: d, encoding: .utf8) else { return "\(v ?? "nil")" }
        return String(s.prefix(n))
    }
    // Enable ALL facets; dump which have values + their structure.
    let setting = "{\"focal_length_group\":true,\"general_tag\":true,\"iso\":true,\"exposure_time_group\":true,\"camera\":true,\"item_type\":true,\"time\":false,\"aperture\":true,\"flash\":true,\"person\":false,\"geocoding\":false,\"favorite\":true,\"rating\":true,\"lens\":true}"
    let r = await raw("SYNO.Foto.Search.Filter", "list_in_similar", [
        URLQueryItem(name: "setting", value: setting),
        URLQueryItem(name: "additional", value: "[\"thumbnail\"]"),
    ])
    let data = r?["data"] as? [String: Any] ?? [:]
    for key in ["camera", "lens", "iso", "aperture", "exposure_time_group", "focal_length_group", "flash", "favorite", "item_type", "general_tag"] {
        let v = data[key]
        let count = (v as? [Any])?.count ?? -1
        print("\(key): count=\(count) → \(jstr(v))")
    }
    // How does list_with_filter accept camera? Grab a camera value id and test.
    if let cameras = data["camera"] as? [[String: Any]], let cam = cameras.first {
        print("\nfirst camera: \(jstr(cam))")
        let camId = cam["id"] ?? cam["name"] ?? "?"
        for key in ["camera"] {
            let resp = await raw("SYNO.Foto.Browse.SimilarItem", "list_with_filter", [
                URLQueryItem(name: "item_type", value: "[0,1]"),
                URLQueryItem(name: key, value: "[\(camId)]"),
                URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "500"),
                URLQueryItem(name: "additional", value: "[\"thumbnail\"]"),
            ])
            let c = (((resp?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []).count
            let code = ((resp?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
            print("list_with_filter \(key)=[\(camId)]: count=\(c) err=\(code)")
        }
    }
}

// MARK: - Find the places (geocoding) list API — names + ids for the filter

func placesProbe() async {
    func jstr(_ v: Any?, _ n: Int = 1200) -> String {
        guard let v, let d = try? JSONSerialization.data(withJSONObject: v), let s = String(data: d, encoding: .utf8) else { return "\(v ?? "nil")" }
        return String(s.prefix(n))
    }
    // 1) Browse.Geocoding list variants.
    for (m, q) in [("list", [URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "20")]),
                   ("list", [URLQueryItem(name: "id", value: "0")])] {
        let r = await raw("SYNO.Foto.Browse.Geocoding", m, q)
        let code = ((r?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
        print("Browse.Geocoding \(m) \(q.map(\.name)): err=\(code) data=\(jstr(r?["data"]))")
    }
    // 1b) Which id space does list_with_filter geocoding accept? a city = flat id 1
    //     (1251 items) vs tree id 2.
    func geoCount(_ id: Int) async -> Int {
        let r = await raw("SYNO.Foto.Browse.SimilarItem", "list_with_filter", [
            URLQueryItem(name: "item_type", value: "[0,1]"),
            URLQueryItem(name: "geocoding", value: "[\(id)]"),
            URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "500"),
            URLQueryItem(name: "additional", value: "[\"thumbnail\"]"),
        ])
        return (((r?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []).count
    }
    print("\nlist_with_filter geocoding=[1] (flat city id): \(await geoCount(1))")
    print("list_with_filter geocoding=[2] (tree city id): \(await geoCount(2))")

    // 2) Search.Filter list_in_similar — the filter panel; its response should
    //    carry geocoding places with names. Send the facet setting like the web.
    let setting = "{\"focal_length_group\":false,\"general_tag\":false,\"iso\":false,\"exposure_time_group\":false,\"camera\":false,\"item_type\":false,\"time\":false,\"aperture\":false,\"flash\":false,\"person\":false,\"geocoding\":true,\"favorite\":false,\"rating\":false,\"lens\":false}"
    let r = await raw("SYNO.Foto.Search.Filter", "list_in_similar", [
        URLQueryItem(name: "setting", value: setting),
        URLQueryItem(name: "additional", value: "[\"thumbnail\"]"),
    ])
    let code = ((r?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
    let data = r?["data"] as? [String: Any]
    print("\nSearch.Filter list_in_similar (geocoding facet): err=\(code) dataKeys=\(data?.keys.sorted() ?? [])")
    if let geo = data?["geocoding"] { print("   geocoding: \(jstr(geo, 1500))") }
    for k in (data?.keys ?? Dictionary<String,Any>().keys) where k != "geocoding" {
        print("   \(k): \(jstr(data?[k], 300))")
    }
}

// MARK: - Verify person / rating filters on list_with_filter

func filterMoreProbe() async {
    func browse(_ q: [URLQueryItem]) async -> [[String: Any]] {
        let r = await raw("SYNO.Foto.Browse.SimilarItem", "list_with_filter",
                          q + [URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "200"),
                               URLQueryItem(name: "additional", value: "[\"thumbnail\",\"person\"]")])
        if let code = ((r?["error"] as? [String: Any])?["code"]) { print("   err=\(code)") }
        return ((r?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
    }
    func hasPerson(_ it: [String: Any], _ pid: Int) -> Bool {
        (((it["additional"] as? [String: Any])?["person"] as? [[String: Any]]) ?? []).contains { ($0["id"] as? Int) == pid }
    }
    // Person filter: person=[2] → all contain person 2? count vs 홍길동's 79.
    let p2 = await browse([URLQueryItem(name: "item_type", value: "[0,1]"),
                           URLQueryItem(name: "person", value: "[2]"), URLQueryItem(name: "person_policy", value: "or")])
    print("person=[2]: count=\(p2.count) allContainP2=\(p2.allSatisfy { hasPerson($0, 2) })")
    // person=[2,4] or → contains 2 OR 4.
    let pOr = await browse([URLQueryItem(name: "item_type", value: "[0,1]"),
                            URLQueryItem(name: "person", value: "[2,4]"), URLQueryItem(name: "person_policy", value: "or")])
    print("person=[2,4] or: count=\(pOr.count)")
    // person=[2,4] and → contains 2 AND 4.
    let pAnd = await browse([URLQueryItem(name: "item_type", value: "[0,1]"),
                             URLQueryItem(name: "person", value: "[2,4]"), URLQueryItem(name: "person_policy", value: "and")])
    let allBoth = pAnd.allSatisfy { hasPerson($0, 2) && hasPerson($0, 4) }
    print("person=[2,4] and: count=\(pAnd.count) allContainBoth=\(allBoth)")
    // Rating: [0] vs [1..5].
    for r in ["[0]", "[1]", "[3]", "[1,2,3,4,5]"] {
        let items = await browse([URLQueryItem(name: "item_type", value: "[0,1]"), URLQueryItem(name: "rating", value: r)])
        print("rating=\(r): count=\(items.count)")
    }
}

// MARK: - Verify the filtered browse (SimilarItem list_with_filter) works

func filterBrowseProbe() async {
    func browse(_ q: [URLQueryItem]) async -> [[String: Any]] {
        let r = await raw("SYNO.Foto.Browse.SimilarItem", "list_with_filter",
                          q + [URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "50"),
                               URLQueryItem(name: "additional", value: "[\"thumbnail\"]")])
        if let code = ((r?["error"] as? [String: Any])?["code"]) { print("   err=\(code)") }
        return ((r?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
    }
    // item_type=[1] → only videos?
    let vids = await browse([URLQueryItem(name: "item_type", value: "[1]")])
    let vidTypes = Set(vids.compactMap { $0["type"] as? String })
    print("item_type=[1]: \(vids.count) items, types=\(vidTypes)")
    // item_type=[0] → only photos?
    let photos = await browse([URLQueryItem(name: "item_type", value: "[0]")])
    let photoTypes = Set(photos.compactMap { $0["type"] as? String })
    print("item_type=[0]: \(photos.count) items, types=\(photoTypes)")
    // item_type=[0,1] → both?
    let both = await browse([URLQueryItem(name: "item_type", value: "[0,1]")])
    print("item_type=[0,1]: \(both.count) items, types=\(Set(both.compactMap { $0["type"] as? String }))")
    // time range: a recent window (last ~30 days from a known ts).
    let end = 1783987199, start = 1783987199 - 30*24*3600
    let timed = await browse([
        URLQueryItem(name: "item_type", value: "[0,1]"),
        URLQueryItem(name: "time", value: "[{\"start_time\":\(start),\"end_time\":\(end)}]"),
    ])
    let times = timed.compactMap { $0["time"] as? Int }
    let inRange = times.allSatisfy { $0 >= start && $0 <= end }
    print("time filter [\(start)..\(end)]: \(timed.count) items, allInRange=\(inRange) sampleTimes=\(times.prefix(3))")
}

// MARK: - Can search results be filtered (item_type / favorite)?

func searchFilterProbe() async {
    func count(_ q: [URLQueryItem]) async -> (Int, String) {
        let r = await raw("SYNO.Foto.Search.Search", "list_item",
                          q + [URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "200")])
        let list = ((r?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
        let code = ((r?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
        return (list.count, code)
    }
    let kw = URLQueryItem(name: "keyword", value: "IMG")
    let base = await count([kw])
    print("baseline keyword=IMG: \(base.0)")
    // item_type filter
    for v in ["photo", "video"] {
        for key in ["item_type", "type"] {
            let r = await count([kw, URLQueryItem(name: key, value: v)])
            print("  \(key)=\(v): count=\(r.0) err=\(r.1) \(r.0 != base.0 ? "≠baseline (filters?)" : "=baseline")")
        }
    }
    // favorite filter
    for key in ["favorite", "is_favorite"] {
        let r = await count([kw, URLQueryItem(name: key, value: "true")])
        print("  \(key)=true: count=\(r.0) err=\(r.1)")
    }
    // Suggest schema (for autocomplete).
    let s = await raw("SYNO.Foto.Search.Search", "suggest", [URLQueryItem(name: "keyword", value: "현")])
    let list = ((s?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
    print("suggest keys: \(list.first?.keys.sorted() ?? [])")
}

// MARK: - Nail down the search API params + result schema

func searchProbe() async {
    func jstr(_ v: Any?) -> String {
        guard let v, let d = try? JSONSerialization.data(withJSONObject: v), let s = String(data: d, encoding: .utf8) else { return "\(v ?? "nil")" }
        return s
    }
    // suggest: autocomplete for a partial keyword.
    for kw in ["현", "IMG", "20"] {
        let r = await raw("SYNO.Foto.Search.Search", "suggest", [URLQueryItem(name: "keyword", value: kw)])
        let list = ((r?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
        print("suggest '\(kw)': \(list.count) → \(jstr(Array(list.prefix(4))))")
    }
    // list_item: actual results. Try each keyword; inspect result count + item schema.
    for kw in ["홍길동", "IMG", "video"] {
        let r = await raw("SYNO.Foto.Search.Search", "list_item", [
            URLQueryItem(name: "keyword", value: kw),
            URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "additional", value: "[\"thumbnail\"]"),
        ])
        let code = ((r?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
        let list = ((r?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
        let first = list.first
        print("\nlist_item '\(kw)': err=\(code) count=\(list.count) firstKeys=\(first?.keys.sorted() ?? []) firstName=\(first?["filename"] ?? "-") type=\(first?["type"] ?? "-")")
    }
}

// MARK: - Explore APIs for video duration / tags / search / geocoding

func exploreFeatures() async {
    func jstr(_ v: Any?) -> String {
        guard let v, let d = try? JSONSerialization.data(withJSONObject: v), let s = String(data: d, encoding: .utf8) else { return "\(v ?? "nil")" }
        return s
    }
    // 1) video_meta additional on a video item → duration?
    var videoId = -1
    for offset in stride(from: 0, to: 2000, by: 200) {
        let r = await raw("SYNO.Foto.Browse.Item", "list", [URLQueryItem(name: "offset", value: "\(offset)"), URLQueryItem(name: "limit", value: "200")])
        let list = ((r?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
        if let v = list.first(where: { ($0["type"] as? String) == "video" }) { videoId = v["id"] as? Int ?? -1; break }
        if list.count < 200 { break }
    }
    print("── video_meta (video id=\(videoId)):")
    let vm = await raw("SYNO.Foto.Browse.Item", "list", [
        URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "500"),
        URLQueryItem(name: "additional", value: "[\"video_meta\",\"thumbnail\"]"),
    ])
    let vlist = ((vm?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
    if let v = vlist.first(where: { ($0["id"] as? Int) == videoId }) {
        print("   additional keys: \((v["additional"] as? [String: Any])?.keys.sorted() ?? [])")
        print("   video_meta: \(jstr((v["additional"] as? [String: Any])?["video_meta"]))")
    }

    // 2) Discover search/tag/geocoding APIs.
    let info = await raw("SYNO.API.Info", "query", [URLQueryItem(name: "query", value: "all")])
    let all = (info?["data"] as? [String: Any])?.keys ?? Dictionary<String,Any>().keys
    let names = all.filter { n in
        let l = n.lowercased()
        return (l.contains("foto")) && (l.contains("search") || l.contains("tag") || l.contains("geo") || l.contains("addressbook") || l.contains("location"))
    }.sorted()
    print("\n── Foto search/tag/geo APIs (\(names.count)):")
    for n in names { print("   \(n)") }

    // 3) Tags: list general tags.
    print("\n── SYNO.Foto.Browse.GeneralTag list:")
    let tags = await raw("SYNO.Foto.Browse.GeneralTag", "list", [URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "10")])
    let tcode = ((tags?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
    let tlist = ((tags?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
    print("   err=\(tcode) count=\(tlist.count) first=\(jstr(tlist.first))")

    // 4) Search: SYNO.Foto.Search.Search or Filter.
    print("\n── search probes:")
    for (api, method) in [("SYNO.Foto.Search.Search", "list_item"), ("SYNO.Foto.Search.Filter", "list"), ("SYNO.Foto.Search.Search", "suggest")] {
        let r = await raw(api, method, [URLQueryItem(name: "keyword", value: "test"), URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "3")])
        let code = ((r?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
        print("   \(api) \(method): err=\(code)\(code == "-" ? " keys=\((r?["data"] as? [String: Any])?.keys.sorted() ?? [])" : "")")
    }
}

// MARK: - Does SYNO.Foto.Download support HTTP Range (needed for streaming)?

func rangeCheck() async {
    // Find a video id.
    var vid = -1; var vname = ""
    for offset in stride(from: 0, to: 2000, by: 200) {
        let r = await raw("SYNO.Foto.Browse.Item", "list", [
            URLQueryItem(name: "offset", value: "\(offset)"), URLQueryItem(name: "limit", value: "200"),
        ])
        let list = ((r?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
        if let v = list.first(where: { ($0["type"] as? String) == "video" }) { vid = v["id"] as? Int ?? -1; vname = v["filename"] as? String ?? ""; break }
        if list.count < 200 { break }
    }
    guard vid > 0 else { print("no video"); return }
    print("video id=\(vid) \(vname)")

    guard let url = client.authenticatedURL(api: "SYNO.Foto.Download", method: "download", queryItems: [
        URLQueryItem(name: "unit_id", value: "[\(vid)]"),
    ]) else { print("no url (not logged in / not discovered)"); return }

    // 1) Range request for the first 1KB.
    var req = URLRequest(url: url)
    req.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
    do {
        let (data, http) = try await client.rawData(for: req)
        let acceptRanges = http.value(forHTTPHeaderField: "Accept-Ranges") ?? "-"
        let contentRange = http.value(forHTTPHeaderField: "Content-Range") ?? "-"
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "-"
        let contentLen = http.value(forHTTPHeaderField: "Content-Length") ?? "-"
        print("status=\(http.statusCode) bytesReturned=\(data.count)")
        print("  Accept-Ranges=\(acceptRanges)  Content-Range=\(contentRange)")
        print("  Content-Type=\(contentType)  Content-Length=\(contentLen)")
        print(http.statusCode == 206 && data.count <= 1024 ? "  ✅ RANGE SUPPORTED (206 partial)" : "  ⚠️ NO RANGE — returned \(data.count)B at status \(http.statusCode) (would download whole file per request)")
    } catch { print("range request failed: \(error)") }

    // 2) A mid-file range to confirm arbitrary seeking works.
    var req2 = URLRequest(url: url)
    req2.setValue("bytes=1000000-1000999", forHTTPHeaderField: "Range")
    if let (data, http) = try? await client.rawData(for: req2) {
        print("mid-range bytes=1000000-1000999: status=\(http.statusCode) bytes=\(data.count) Content-Range=\(http.value(forHTTPHeaderField: "Content-Range") ?? "-")")
    }
}

// MARK: - Verify a video downloads and is actually playable by AVFoundation

func videoCheck() async {
    // Find a video item in the timeline.
    var found: (id: Int, name: String)?
    for offset in stride(from: 0, to: 2000, by: 200) {
        let r = await raw("SYNO.Foto.Browse.Item", "list", [
            URLQueryItem(name: "offset", value: "\(offset)"), URLQueryItem(name: "limit", value: "200"),
            URLQueryItem(name: "additional", value: "[\"thumbnail\"]"),
        ])
        let list = ((r?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
        if let v = list.first(where: { ($0["type"] as? String) == "video" }) {
            found = (v["id"] as? Int ?? -1, v["filename"] as? String ?? "video"); break
        }
        if list.count < 200 { break }
    }
    guard let video = found else { print("no video items found in library"); return }
    print("video item: id=\(video.id) name=\(video.name)")

    // Download the original via SYNO.Foto.Download (same endpoint the app uses).
    let ext = (video.name as NSString).pathExtension
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("videocheck.\(ext.isEmpty ? "mov" : ext)")
    try? FileManager.default.removeItem(at: tmp)
    do {
        try await client.downloadToFile(api: "SYNO.Foto.Download", method: "download", queryItems: [
            URLQueryItem(name: "unit_id", value: "[\(video.id)]"),
        ], to: tmp)
    } catch { print("download failed: \(error)"); return }
    let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? 0
    print("downloaded \(size ?? 0) bytes to \(tmp.lastPathComponent)")

    // Ask AVFoundation whether it's playable (this is exactly what AVPlayer uses).
    let asset = AVURLAsset(url: tmp)
    do {
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        print("AVFoundation: isPlayable=\(playable) duration=\(CMTimeGetSeconds(duration))s videoTracks=\(tracks.count) \(playable ? "✅ WILL PLAY" : "⚠️ needs transcode")")
    } catch {
        print("AVAsset load error: \(error)")
    }
    try? FileManager.default.removeItem(at: tmp)
}

// MARK: - How many people does the app get vs. what filters exist?

func peopleCount() async {
    func listCount(_ extra: [URLQueryItem], label: String) async {
        let r = await raw("SYNO.Foto.Browse.Person", "list",
                          [URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "1000")] + extra)
        let code = ((r?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
        let list = ((r?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
        let named = list.filter { !(($0["name"] as? String) ?? "").isEmpty }.count
        let showTrue = list.filter { ($0["show"] as? Bool) == true }.count
        print("  \(label): err=\(code) total=\(list.count) named=\(named) show=true:\(showTrue)")
    }
    // Baseline (what the app currently does).
    await listCount([URLQueryItem(name: "additional", value: "[\"thumbnail\"]")], label: "app default")
    // Variants that might reveal more people.
    await listCount([URLQueryItem(name: "additional", value: "[\"thumbnail\"]"), URLQueryItem(name: "show_more", value: "true")], label: "show_more=true")
    await listCount([URLQueryItem(name: "additional", value: "[\"thumbnail\"]"), URLQueryItem(name: "additional_type", value: "all")], label: "additional_type=all")

    // The person `count` method, if any.
    let cnt = await raw("SYNO.Foto.Browse.Person", "count", [])
    print("  Person.count: \((cnt?["data"] as? [String: Any])?["count"] ?? "?") err=\(((cnt?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-")")

    // Distribution of `show` and whether there are named people beyond the list.
    let r = await raw("SYNO.Foto.Browse.Person", "list", [URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "1000")])
    let list = ((r?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
    let namedList = list.filter { !(($0["name"] as? String) ?? "").isEmpty }.map { "\($0["name"] as? String ?? "")(\($0["item_count"] as? Int ?? -1))" }
    print("\n  NAMED people (\(namedList.count)): \(namedList.joined(separator: ", "))")
    let showFalse = list.filter { ($0["show"] as? Bool) == false }
    print("  people with show=false: \(showFalse.count)")
}

// MARK: - Verify type=person id=<person_id> gives a real crop for EVERY person

func faceVerify() async {
    let placeholderSHA = "af845880d2a22ccfc640acdd0318f0dff49ec8b5617428b4d7b152ba0d1590a5"
    let r = await raw("SYNO.Foto.Browse.Person", "list", [
        URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "40"),
        URLQueryItem(name: "additional", value: "[\"thumbnail\"]"),
    ])
    let people = ((r?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
    var placeholders = 0, reals = 0, empties = 0
    for p in people {
        let pid = p["id"] as? Int ?? -1
        let name = (p["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(unnamed)"
        let ck = ((p["additional"] as? [String: Any])?["thumbnail"] as? [String: Any])?["cache_key"] as? String ?? ""
        // The fix: type=person, id = the PERSON id (not cover).
        let d = (try? await client.requestData(api: "SYNO.Foto.Thumbnail", method: "get", queryItems: [
            URLQueryItem(name: "id", value: "\(pid)"), URLQueryItem(name: "cache_key", value: ck),
            URLQueryItem(name: "type", value: "person"), URLQueryItem(name: "size", value: "sm"),
        ])) ?? Data()
        let sha = Data(SHA256.hash(data: d)).map { String(format: "%02x", $0) }.joined()
        let state = d.isEmpty ? "EMPTY" : (sha == placeholderSHA ? "PLACEHOLDER" : "real \(d.count)B")
        if d.isEmpty { empties += 1 } else if sha == placeholderSHA { placeholders += 1 } else { reals += 1 }
        print("  \(name) id=\(pid): \(state)")
    }
    print("\nreal: \(reals)  placeholder: \(placeholders)  empty: \(empties)  (of \(people.count))")
}

// MARK: - Hunt for how the web gets a tight face crop for EVERY person

func faceHunt() async {
    func jstr(_ v: Any?) -> String {
        guard let v, let d = try? JSONSerialization.data(withJSONObject: v), let s = String(data: d, encoding: .utf8) else { return "\(v ?? "nil")" }
        return s
    }
    // 1) Full person object with many additional keys — hunt for a face rectangle/id.
    for addl in ["[\"thumbnail\"]", "[\"thumbnail\",\"face\"]", "[\"thumbnail\",\"face_rect\"]", "[\"thumbnail\",\"person_thumbnail\"]", "[\"thumbnail\",\"rect\"]"] {
        let r = await raw("SYNO.Foto.Browse.Person", "list", [
            URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "3"),
            URLQueryItem(name: "additional", value: addl),
        ])
        let code = ((r?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
        let first = ((r?["data"] as? [String: Any])?["list"] as? [[String: Any]])?.first
        print("Person.list additional=\(addl): err=\(code) keys=\(first?.keys.sorted() ?? [])")
        if code == "-" , let first { print("   person[0]=\(jstr(first))") }
    }

    // 2) Candidate face-listing methods on Browse.Person.
    print("\n── method existence (id=2):")
    for m in ["list_face", "get_face", "list_faces", "face", "get", "list_item"] {
        let r = await raw("SYNO.Foto.Browse.Person", m, [URLQueryItem(name: "id", value: "2")])
        let code = ((r?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
        print("   \(m): err=\(code)\(code == "103" ? " absent" : " EXISTS")")
        if code == "-" { print("      data=\(jstr((r?["data"]))))") }
    }

    // 3) Is there a separate face API?
    print("\n── discover face/recognition APIs:")
    let info = await raw("SYNO.API.Info", "query", [URLQueryItem(name: "query", value: "SYNO.Foto.Browse.Person,SYNO.Foto.Browse.RecognitionFace,SYNO.Foto.Browse.Face,SYNO.FotoTeam.Browse.Person")])
    if let data = info?["data"] as? [String: Any] { print("   known: \(data.keys.sorted())") }

    // 4) type=face thumbnail on 홍길동's cover, and re-check type=person now.
    print("\n── 홍길동 (id=2) cover thumbnail re-check:")
    let pl = await raw("SYNO.Foto.Browse.Person", "list", [URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "3"), URLQueryItem(name: "additional", value: "[\"thumbnail\"]")])
    let p2 = ((pl?["data"] as? [String: Any])?["list"] as? [[String: Any]])?.first { ($0["id"] as? Int) == 2 }
    let cover = p2?["cover"] as? Int ?? -1
    let ck = ((p2?["additional"] as? [String: Any])?["thumbnail"] as? [String: Any])?["cache_key"] as? String ?? ""
    for type in ["person", "face"] {
        for id in [cover, 2] {
            let d = try? await client.requestData(api: "SYNO.Foto.Thumbnail", method: "get", queryItems: [
                URLQueryItem(name: "id", value: "\(id)"), URLQueryItem(name: "cache_key", value: ck),
                URLQueryItem(name: "type", value: type), URLQueryItem(name: "size", value: "sm"),
            ])
            print("   type=\(type) id=\(id): \(d?.count ?? 0)B")
        }
    }
}

// MARK: - Cover audit: for each person, which thumbnail call returns an image?

func coverAudit() async {
    let r = await raw("SYNO.Foto.Browse.Person", "list", [
        URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "16"),
        URLQueryItem(name: "additional", value: "[\"thumbnail\"]"),
    ])
    let people = ((r?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []

    func bytes(_ id: Int, _ ck: String, _ type: String, _ size: String) async -> Int {
        let d = try? await client.requestData(api: "SYNO.Foto.Thumbnail", method: "get", queryItems: [
            URLQueryItem(name: "id", value: "\(id)"), URLQueryItem(name: "cache_key", value: ck),
            URLQueryItem(name: "type", value: type), URLQueryItem(name: "size", value: size),
        ])
        return d?.count ?? 0
    }

    for p in people {
        let pid = p["id"] as? Int ?? -1
        let name = (p["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(unnamed)"
        let cover = p["cover"] as? Int ?? -1
        let ck = ((p["additional"] as? [String: Any])?["thumbnail"] as? [String: Any])?["cache_key"] as? String ?? ""
        let ckPrefix = Int(ck.split(separator: "_").first ?? "") ?? -1
        // Test the combinations my loader could use.
        let personCrop = await bytes(cover, ck, "person", "sm")
        let personCropM = await bytes(cover, ck, "person", "m")
        let unitCover = await bytes(cover, ck, "unit", "sm")
        let unitPrefix = await bytes(ckPrefix, ck, "unit", "sm")
        let personPrefix = await bytes(ckPrefix, ck, "person", "sm")
        func f(_ n: Int) -> String { n > 1000 ? "\(n/1000)KB" : (n == 0 ? "✗" : "\(n)B") }
        print("\(name) id=\(pid) cover=\(cover) ckPrefix=\(ckPrefix): person(cover)sm=\(f(personCrop)) m=\(f(personCropM)) | unit(cover)=\(f(unitCover)) | unit(prefix)=\(f(unitPrefix)) person(prefix)=\(f(personPrefix))")
    }

    // Is the "11KB" person-crop a byte-identical placeholder? Hash two of them.
    print("\n── placeholder stability check")
    func hashOf(_ id: Int, _ ck: String) async -> (Int, String) {
        let d = (try? await client.requestData(api: "SYNO.Foto.Thumbnail", method: "get", queryItems: [
            URLQueryItem(name: "id", value: "\(id)"), URLQueryItem(name: "cache_key", value: ck),
            URLQueryItem(name: "type", value: "person"), URLQueryItem(name: "size", value: "sm"),
        ])) ?? Data()
        return (d.count, Data(SHA256.hash(data: d)).prefix(6).map { String(format: "%02x", $0) }.joined())
    }
    // Full SHA256 of the placeholder (from a known no-crop person, e.g. id=2).
    if let p2 = people.first(where: { ($0["id"] as? Int) == 2 }) {
        let cover = p2["cover"] as? Int ?? -1
        let ck = ((p2["additional"] as? [String: Any])?["thumbnail"] as? [String: Any])?["cache_key"] as? String ?? ""
        let d = (try? await client.requestData(api: "SYNO.Foto.Thumbnail", method: "get", queryItems: [
            URLQueryItem(name: "id", value: "\(cover)"), URLQueryItem(name: "cache_key", value: ck),
            URLQueryItem(name: "type", value: "person"), URLQueryItem(name: "size", value: "sm"),
        ])) ?? Data()
        let full = Data(SHA256.hash(data: d)).map { String(format: "%02x", $0) }.joined()
        print("  placeholder sm: size=\(d.count) fullSHA256=\(full)")
    }
}

// MARK: - Audit a person's photos: correctness of filter + thumbnail readiness

func personPhotosAudit() async {
    let pid = Int(CommandLine.arguments.dropFirst(2).first ?? "2") ?? 2
    let r = await raw("SYNO.Foto.Browse.Item", "list", [
        URLQueryItem(name: "person_id", value: "\(pid)"),
        URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "100"),
        URLQueryItem(name: "sort_by", value: "takentime"), URLQueryItem(name: "sort_direction", value: "desc"),
        URLQueryItem(name: "additional", value: "[\"thumbnail\",\"person\"]"),
    ])
    let list = ((r?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
    print("person_id=\(pid): returned \(list.count) items\n")

    // Authoritative counts to compare with the person tile's item_count (61).
    let cnt = await raw("SYNO.Foto.Browse.Item", "count", [URLQueryItem(name: "person_id", value: "\(pid)")])
    print("Browse.Item count person_id=\(pid): \((cnt?["data"] as? [String: Any])?["count"] ?? "?")")
    // Does the person tile's item_count match? (from Person.list)
    let pl = await raw("SYNO.Foto.Browse.Person", "list", [URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "80")])
    let tile = ((pl?["data"] as? [String: Any])?["list"] as? [[String: Any]])?.first { ($0["id"] as? Int) == pid }
    print("Person tile item_count: \(tile?["item_count"] ?? "?")\n")

    var missingThumb = 0, mNotReady = 0, smNotReady = 0, notContainingPerson = 0
    var readyM = 0
    for it in list {
        let thumb = (it["additional"] as? [String: Any])?["thumbnail"] as? [String: Any]
        if thumb == nil { missingThumb += 1 }
        let sm = thumb?["sm"] as? String, m = thumb?["m"] as? String, xl = thumb?["xl"] as? String
        if m != "ready" { mNotReady += 1 }
        if sm != "ready" { smNotReady += 1 }
        if m == "ready" { readyM += 1 }
        // Does this item actually contain person 2?
        let persons = ((it["additional"] as? [String: Any])?["person"] as? [[String: Any]]) ?? []
        let hasP = persons.contains { ($0["id"] as? Int) == pid }
        if !hasP { notContainingPerson += 1 }
        _ = (sm, xl)
    }
    print("thumbnail readiness across \(list.count):")
    print("  missing thumbnail dict: \(missingThumb)")
    print("  m NOT ready: \(mNotReady)   (m ready: \(readyM))")
    print("  sm NOT ready: \(smNotReady)")
    print("filter correctness:")
    print("  items NOT containing person \(pid): \(notContainingPerson)  \(notContainingPerson == 0 ? "✓ all correct" : "⚠️ WRONG PHOTOS PRESENT")")
    // Show a few thumbnail states.
    for it in list.prefix(8) {
        let t = (it["additional"] as? [String: Any])?["thumbnail"] as? [String: Any]
        print("  id=\(it["id"] as? Int ?? -1) sm=\(t?["sm"] ?? "-") m=\(t?["m"] ?? "-") xl=\(t?["xl"] ?? "-") unit=\(t?["unit_id"] ?? "-")")
    }
}

// MARK: - Verify set_cover (photo_id) works, then restore person 2's cover

func personSetCoverVerify() async {
    let pid = 2
    func cover() async -> (id: Int, cacheKey: String) {
        let r = await raw("SYNO.Foto.Browse.Person", "list", [
            URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "80"),
            URLQueryItem(name: "additional", value: "[\"thumbnail\"]"),
        ])
        let list = ((r?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
        let p = list.first { ($0["id"] as? Int) == pid }
        let ck = ((p?["additional"] as? [String: Any])?["thumbnail"] as? [String: Any])?["cache_key"] as? String ?? ""
        return (p?["cover"] as? Int ?? -1, ck)
    }
    func setCover(_ photoId: Int) async -> String {
        let r = await raw("SYNO.Foto.Browse.Person", "set_cover", [
            URLQueryItem(name: "id", value: "\(pid)"), URLQueryItem(name: "photo_id", value: "\(photoId)"),
        ])
        let ok = (r?["success"] as? Bool) == true
        return ok ? "✓ success" : "fail err=\(((r?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "?")"
    }

    let before = await cover()
    // cache_key prefix = the current cover PHOTO's unit/item id (to restore to).
    let originalPhoto = Int(before.cacheKey.split(separator: "_").first ?? "") ?? -1
    print("before: cover face id=\(before.id), cover photo(from cache_key)=\(originalPhoto)")

    // Grab two real person-2 photos (correct person_id filter).
    let items = ((await raw("SYNO.Foto.Browse.Item", "list", [
        URLQueryItem(name: "person_id", value: "\(pid)"),
        URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "10"),
    ]))?["data"] as? [String: Any]).flatMap { ($0["list"] as? [[String: Any]]) } ?? []
    let ids = items.compactMap { $0["id"] as? Int }
    guard let newPhoto = ids.first(where: { $0 != originalPhoto }) else { print("no alt photo"); return }

    print("set_cover photo_id=\(newPhoto): \(await setCover(newPhoto))")
    let mid = await cover()
    print("  → cover face id now=\(mid.id) (changed: \(mid.id != before.id ? "✓" : "✗"))")

    // Restore to the original cover photo.
    print("restore set_cover photo_id=\(originalPhoto): \(await setCover(originalPhoto))")
    let after = await cover()
    print("  → cover face id=\(after.id) \(after.id == before.id ? "✓ RESTORED to original" : "⚠️ now \(after.id), was \(before.id)")")
}

// MARK: - Find the param that actually filters items by person

func personFilterProbe() async {
    let pid = 2  // 홍길동, item_count 61
    func ids(_ query: [URLQueryItem]) async -> (ids: [Int], err: String) {
        let r = await raw("SYNO.Foto.Browse.Item", "list",
                          query + [URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "100")])
        let list = ((r?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
        let code = ((r?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
        return (list.compactMap { $0["id"] as? Int }, code)
    }
    // Baseline: unfiltered recent items.
    let base = await ids([])
    print("unfiltered: \(base.ids.count) items, first=\(base.ids.prefix(3))\n")
    print("target person \(pid) has item_count=61 — a correct filter returns ~61 DIFFERENT items:\n")

    let candidates: [(String, [URLQueryItem])] = [
        ("person=2", [URLQueryItem(name: "person", value: "\(pid)")]),
        ("person_id=2", [URLQueryItem(name: "person_id", value: "\(pid)")]),
        ("person=[2]", [URLQueryItem(name: "person", value: "[\(pid)]")]),
        ("person_ids=[2]", [URLQueryItem(name: "person_ids", value: "[\(pid)]")]),
        ("person_id=[2]", [URLQueryItem(name: "person_id", value: "[\(pid)]")]),
        ("passphrase_person", [URLQueryItem(name: "person_id", value: "\(pid)"), URLQueryItem(name: "type", value: "person")]),
    ]
    for (label, q) in candidates {
        let r = await ids(q)
        let differs = Set(r.ids) != Set(base.ids)
        print("  \(label): count=\(r.ids.count) err=\(r.err) differsFromBaseline=\(differs)\(differs ? " ✓ FILTERS" : "")")
    }
}

// MARK: - Find + verify the set-cover API (reversible on a named person)

func personCoverProbe() async {
    let pid = 2
    func coverOf(_ id: Int) async -> Int {
        let r = await raw("SYNO.Foto.Browse.Person", "list", [
            URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "80"),
            URLQueryItem(name: "additional", value: "[\"thumbnail\"]"),
        ])
        let list = ((r?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
        return (list.first { ($0["id"] as? Int) == id }?["cover"] as? Int) ?? -1
    }

    // Inspect a few of this person's photos (CORRECT filter = person_id).
    let itemsResp = await raw("SYNO.Foto.Browse.Item", "list", [
        URLQueryItem(name: "person_id", value: "\(pid)"),
        URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "6"),
        URLQueryItem(name: "additional", value: "[\"thumbnail\"]"),
    ])
    let items = ((itemsResp?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
    print("person \(pid) sample photos (id / unit_id):")
    for it in items {
        let iid = it["id"] as? Int ?? -1
        let unit = ((it["additional"] as? [String: Any])?["thumbnail"] as? [String: Any])?["unit_id"] as? Int ?? -1
        print("  id=\(iid) unit_id=\(unit)")
    }
    // Does person= actually FILTER? Compare person=2 vs person=4 first ids.
    let p4 = await raw("SYNO.Foto.Browse.Item", "list", [
        URLQueryItem(name: "person", value: "4"),
        URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "6"),
    ])
    let p4ids = ((p4?["data"] as? [String: Any])?["list"] as? [[String: Any]])?.compactMap { $0["id"] as? Int } ?? []
    let p2ids = items.compactMap { $0["id"] as? Int }
    print("person=2 ids: \(p2ids)")
    print("person=4 ids: \(p4ids)  filter working: \(Set(p2ids) != Set(p4ids))")

    let original = await coverOf(pid)
    print("current cover=\(original)")

    // Is cover an ITEM id? Check person 2's OLDEST photos (asc) — does one == 349?
    let oldest = await raw("SYNO.Foto.Browse.Item", "list", [
        URLQueryItem(name: "person", value: "\(pid)"),
        URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "6"),
        URLQueryItem(name: "sort_by", value: "takentime"), URLQueryItem(name: "sort_direction", value: "asc"),
    ])
    let oldestItems = ((oldest?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
    print("oldest item ids: \(oldestItems.compactMap { $0["id"] as? Int })")
    let coverIsItem = oldestItems.contains { ($0["id"] as? Int) == original }
    print("cover(\(original)) is one of person's item ids: \(coverIsItem)")

    // Pick a candidate DIFFERENT from current cover to prove the param works.
    let candItem = items.first { ($0["id"] as? Int) != original }
    let candItemId = candItem?["id"] as? Int ?? -1
    let candUnit = ((candItem?["additional"] as? [String: Any])?["thumbnail"] as? [String: Any])?["unit_id"] as? Int ?? candItemId
    print("candidate new cover: item id=\(candItemId) unit_id=\(candUnit)\n")

    // `set` seems to require `name`; include it (JSON) alongside each cover shape.
    let curName = "\"홍길동\""
    func base() -> [URLQueryItem] { [URLQueryItem(name: "id", value: "\(pid)"), URLQueryItem(name: "name", value: curName)] }
    let attempts: [(String, [URLQueryItem])] = [
        ("name + cover=itemId",    base() + [URLQueryItem(name: "cover", value: "\(candItemId)")]),
        ("name + cover_id=itemId", base() + [URLQueryItem(name: "cover_id", value: "\(candItemId)")]),
        ("name + item_id=itemId",  base() + [URLQueryItem(name: "item_id", value: "\(candItemId)")]),
        ("name + cover=[itemId]",  base() + [URLQueryItem(name: "cover", value: "[\(candItemId)]")]),
    ]
    // First: which METHOD owns cover? 117 = exists (wrong params), 103 = absent.
    print("── method existence probe (id+cover params):")
    for method in ["set_cover", "update_cover", "cover", "set_thumbnail", "set_face", "set_face_cover", "update"] {
        let r = await raw("SYNO.Foto.Browse.Person", method, [
            URLQueryItem(name: "id", value: "\(pid)"), URLQueryItem(name: "cover", value: "\(candItemId)"),
        ])
        let code = ((r?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
        let ok = (r?["success"] as? Bool) == true
        let now = await coverOf(pid)
        let changed = now != original
        print("  \(method): success=\(ok) err=\(code)\(code == "103" ? " (absent)" : " (EXISTS)")\(changed ? " → cover CHANGED to \(now)" : "")")
        if changed {  // revert immediately if something took effect
            _ = await raw("SYNO.Foto.Browse.Person", method, [
                URLQueryItem(name: "id", value: "\(pid)"), URLQueryItem(name: "cover", value: "\(original)"),
            ])
            print("   reverted → cover=\(await coverOf(pid))")
        }
    }

    // The cover photo (unit 3687 per cache_key) is in person 2's list. Its
    // `person` additional should carry the face id (349). Dump it.
    let faceProbe = await raw("SYNO.Foto.Browse.Item", "list", [
        URLQueryItem(name: "person_id", value: "\(pid)"),
        URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "6"),
        URLQueryItem(name: "additional", value: "[\"thumbnail\",\"person\"]"),
    ])
    let faceItems = ((faceProbe?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
    for it in faceItems {
        let iid = it["id"] as? Int ?? -1
        if let raw = (it["additional"] as? [String: Any])?["person"],
           let j = try? JSONSerialization.data(withJSONObject: raw),
           let s = String(data: j, encoding: .utf8) {
            print("   item \(iid) person additional JSON: \(s)")
        }
    }

    // set_cover EXISTS — find its exact param. Try each; revert on any change.
    print("── set_cover param probe (candidate value \(candItemId)):")
    var worked: (label: String, method: String, param: String)?
    let n = "\"홍길동\""
    let coverAttempts: [(String, String, [URLQueryItem])] = [
        ("set cover=item", "set", [URLQueryItem(name: "id", value: "\(pid)"), URLQueryItem(name: "name", value: n), URLQueryItem(name: "cover", value: "\(candItemId)")]),
        ("set_cover person_id+item_id", "set_cover", [URLQueryItem(name: "person_id", value: "\(pid)"), URLQueryItem(name: "item_id", value: "\(candItemId)")]),
        ("set_cover id+id_item", "set_cover", [URLQueryItem(name: "id", value: "\(pid)"), URLQueryItem(name: "id_item", value: "\(candItemId)")]),
        ("set_cover id+cover", "set_cover", [URLQueryItem(name: "id", value: "\(pid)"), URLQueryItem(name: "cover", value: "\(candItemId)")]),
        ("set_cover id+unit_id", "set_cover", [URLQueryItem(name: "id", value: "\(pid)"), URLQueryItem(name: "unit_id", value: "\(candUnit)")]),
        ("set_cover id+item_id", "set_cover", [URLQueryItem(name: "id", value: "\(pid)"), URLQueryItem(name: "item_id", value: "\(candItemId)")]),
    ]
    for (label, method, query) in coverAttempts {
        let r = await raw("SYNO.Foto.Browse.Person", method, query)
        let ok = (r?["success"] as? Bool) == true
        let code = ((r?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
        let now = await coverOf(pid)
        let changed = now != original
        print("  \(label): success=\(ok) err=\(code) → cover=\(now) \(changed ? "✓ CHANGED" : "")")
        if changed { worked = (label, method, query.last!.name); break }
    }

    // Revert to the original cover using the working method/param.
    if let w = worked {
        _ = await raw("SYNO.Foto.Browse.Person", w.method, [
            URLQueryItem(name: "id", value: "\(pid)"), URLQueryItem(name: w.param, value: "\(original)"),
        ])
        let reverted = await coverOf(pid)
        print("\n✅ set-cover works: \(w.label) (method=\(w.method) param=\(w.param))")
        print("   reverted cover=\(reverted) \(reverted == original ? "✓ restored" : "⚠️ NOT restored (was \(original)) — REVERT MANUALLY")")
    } else {
        print("\n⚠️ no set-cover shape matched — needs the web client's exact call")
    }
}

// MARK: - Verify JSON-quoted name sets correctly (no-op on a named person)

func personJsonSet() async {
    let pid = 2
    func nameOf(_ id: Int) async -> String {
        let r = await raw("SYNO.Foto.Browse.Person", "list", [
            URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "80"),
        ])
        let list = ((r?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
        return (list.first { ($0["id"] as? Int) == id }?["name"] as? String) ?? "?"
    }
    let original = await nameOf(pid)
    print("id=\(pid) name before: \"\(original)\"")
    // Send the SAME name but JSON-quoted; verify it stores unquoted (no-op).
    let json = (try? String(data: JSONEncoder().encode(original), encoding: .utf8)) ?? "\"\(original)\""
    let r = await raw("SYNO.Foto.Browse.Person", "set", [
        URLQueryItem(name: "id", value: "\(pid)"), URLQueryItem(name: "name", value: json),
    ])
    let ok = (r?["success"] as? Bool) == true
    let after = await nameOf(pid)
    print("  set name=\(json): success=\(ok) → name=\"\(after)\" \(after == original ? "✓ correct (no quotes stored)" : "⚠️ MISMATCH")")
}

// MARK: - Revert: clear the test name off cluster 82 (find the un-name mechanism)

func personUnname() async {
    let pid = 82
    func nameOf(_ id: Int) async -> String {
        let r = await raw("SYNO.Foto.Browse.Person", "list", [
            URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "80"),
        ])
        let list = ((r?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
        return (list.first { ($0["id"] as? Int) == id }?["name"] as? String) ?? "?"
    }
    print("id=\(pid) current name: \"\(await nameOf(pid))\"")

    // Candidate ways to clear a name (name-only; NOT the cluster-deleting `delete`).
    let attempts: [(String, [URLQueryItem])] = [
        ("set name= (empty)", [URLQueryItem(name: "id", value: "\(pid)"), URLQueryItem(name: "name", value: "")]),
        ("set name=\"\" (json empty)", [URLQueryItem(name: "id", value: "\(pid)"), URLQueryItem(name: "name", value: "\"\"")]),
        ("set + show=false", [URLQueryItem(name: "id", value: "\(pid)"), URLQueryItem(name: "name", value: ""), URLQueryItem(name: "show", value: "false")]),
    ]
    for (label, query) in attempts {
        let r = await raw("SYNO.Foto.Browse.Person", "set", query)
        let ok = (r?["success"] as? Bool) == true
        let code = ((r?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
        let now = await nameOf(pid)
        print("  \(label): success=\(ok) err=\(code) → name=\"\(now)\" \(now.isEmpty ? "✓ CLEARED" : "")")
        if now.isEmpty { print("  ✅ reverted"); return }
    }
    print("  ⚠️ could not clear via `set` — will need the web-client's un-name call")
}

// MARK: - Person rename ROUND-TRIP — reversible: name an UNNAMED cluster, then clear it

func personRenameRoundtrip() async {
    func peopleNow() async -> [[String: Any]] {
        let r = await raw("SYNO.Foto.Browse.Person", "list", [
            URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "80"),
        ])
        return ((r?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
    }
    func name(of pid: Int) async -> String {
        (await peopleNow().first { ($0["id"] as? Int) == pid }?["name"] as? String) ?? "?"
    }

    // Pick an UNNAMED cluster so the change is trivially reversible (clear→unnamed).
    guard let target = (await peopleNow()).first(where: { (($0["name"] as? String) ?? "").isEmpty }),
          let pid = target["id"] as? Int else {
        print("no unnamed cluster to round-trip on"); return
    }
    let temp = "테스트_임시_이름"
    print("round-trip on UNNAMED cluster id=\(pid) (was: \"\")")

    _ = await raw("SYNO.Foto.Browse.Person", "set", [
        URLQueryItem(name: "id", value: "\(pid)"), URLQueryItem(name: "name", value: temp),
    ])
    let named = await name(of: pid)
    print("  after set \"\(temp)\": name=\"\(named)\" \(named == temp ? "✓ persisted" : "⚠️")")

    _ = await raw("SYNO.Foto.Browse.Person", "set", [
        URLQueryItem(name: "id", value: "\(pid)"), URLQueryItem(name: "name", value: ""),
    ])
    let cleared = await name(of: pid)
    print("  after clear: name=\"\(cleared)\" \(cleared.isEmpty ? "✓ reverted to unnamed" : "⚠️ NOT reverted")")
}

// MARK: - Discover which API owns person naming

func personApiProbe() async {
    // Ask SYNO.API.Info for the full API catalog, filter person/face-related.
    let resp = await raw("SYNO.API.Info", "query", [
        URLQueryItem(name: "query", value: "all"),
    ])
    let data = (resp?["data"] as? [String: Any]) ?? [:]
    let names = data.keys.filter {
        let l = $0.lowercased()
        return l.contains("person") || l.contains("face") || l.contains("recogni")
    }.sorted()
    print("person/face-related APIs (\(names.count)):")
    for n in names {
        let info = data[n] as? [String: Any] ?? [:]
        print("  • \(n)  maxVersion=\(info["maxVersion"] ?? "?") path=\(info["path"] ?? "?")")
    }
    // Some DSMs put naming on Browse.Person under a different method — dump the
    // method list if the API exposes one via a bad-method error hint isn't
    // possible, so just try a few more method names quietly.
    for method in ["set_person", "name", "update", "modify", "set"] {
        let r = await raw("SYNO.Foto.Browse.Person", method, [
            URLQueryItem(name: "id", value: "0"), URLQueryItem(name: "name", value: "x"),
        ])
        let code = ((r?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
        print("  Browse.Person \(method): err=\(code)\(code == "103" ? " (no such method)" : " (method EXISTS)")")
    }
}

// MARK: - Person rename probe — SAFE (no-op: re-set a named person's SAME name)

func personRenameProbe() async {
    // Grab the current people so we can no-op an already-named one.
    let resp = await raw("SYNO.Foto.Browse.Person", "list", [
        URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "50"),
    ])
    let people = ((resp?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
    guard let named = people.first(where: { !(($0["name"] as? String) ?? "").isEmpty }),
          let pid = named["id"] as? Int, let currentName = named["name"] as? String else {
        print("no named person to no-op test on"); return
    }
    print("no-op rename target: id=\(pid) name=\"\(currentName)\" (setting SAME name)\n")

    // `set` EXISTS (err=117 = wrong params). Find its param shape via no-ops.
    let q = currentName
    let jsonName = "\"\(q)\""
    let candidates: [(String, String, [URLQueryItem])] = [
        ("SYNO.Foto.Browse.Person", "set", [URLQueryItem(name: "id", value: "\(pid)"), URLQueryItem(name: "name", value: q)]),
        ("SYNO.Foto.Browse.Person", "set", [URLQueryItem(name: "id", value: "\(pid)"), URLQueryItem(name: "name", value: jsonName)]),
        ("SYNO.Foto.Browse.Person", "set", [URLQueryItem(name: "id", value: "[\(pid)]"), URLQueryItem(name: "name", value: q)]),
        ("SYNO.Foto.Browse.Person", "set", [URLQueryItem(name: "person_id", value: "\(pid)"), URLQueryItem(name: "name", value: q)]),
        ("SYNO.Foto.Browse.Person", "set", [URLQueryItem(name: "id", value: "\(pid)"), URLQueryItem(name: "name", value: q), URLQueryItem(name: "show", value: "true")]),
    ]
    for (api, method, query) in candidates {
        let r = await raw(api, method, query)
        let ok = (r?["success"] as? Bool) == true
        let code = ((r?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "-"
        print("  \(api) \(method) [\(query.map(\.name).joined(separator: ","))]: \(ok ? "✓ SUCCESS" : "fail err=\(code)")")
        if ok {
            // Confirm the name is unchanged (it was a no-op).
            let after = await raw("SYNO.Foto.Browse.Person", "list", [
                URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "50"),
            ])
            let now = (((after?["data"] as? [String: Any])?["list"] as? [[String: Any]])?
                .first { ($0["id"] as? Int) == pid }?["name"] as? String) ?? "?"
            print("  → verified name still \"\(now)\" \(now == currentName ? "✓ unchanged" : "⚠️ CHANGED")")
            return
        }
    }
    print("  no rename method matched — inspect DSM web client for the exact call")
}

// MARK: - Album create/delete (no photos touched)

func albumTest() async {
    let name = "⚠️TEST_DELETE_\(UUID().uuidString.prefix(8))"
    print("── Album create: '\(name)'")
    let created = await raw("SYNO.Foto.Browse.NormalAlbum", "create", [
        URLQueryItem(name: "name", value: name),
        URLQueryItem(name: "item", value: "[]"),
    ])
    print("   create response: \(created ?? [:])")

    guard let data = created?["data"] as? [String: Any] else {
        print("   ✘ create failed — not proceeding to delete"); return
    }
    // id might be under data.album.id or data.id
    let albumId = (data["album"] as? [String: Any])?["id"] as? Int ?? data["id"] as? Int
    guard let albumId else { print("   ✘ no album id in response"); return }
    print("   ✓ created album id=\(albumId)")

    // Confirm it lists
    let list = await raw("SYNO.Foto.Browse.Album", "list", [
        URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "100"),
    ])
    let albums = ((list?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
    let found = albums.contains { ($0["id"] as? Int) == albumId }
    print("   listed after create: found=\(found) (total albums=\(albums.count))")

    // Delete it
    print("── Album delete: id=\(albumId)")
    let deleted = await raw("SYNO.Foto.Browse.NormalAlbum", "delete", [
        URLQueryItem(name: "id", value: "[\(albumId)]"),
    ])
    print("   delete response: \(deleted ?? [:])")
    let list2 = await raw("SYNO.Foto.Browse.Album", "list", [
        URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "100"),
    ])
    let albums2 = ((list2?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
    let stillThere = albums2.contains { ($0["id"] as? Int) == albumId }
    print("   \(stillThere ? "⚠️ still present" : "✓ gone after delete")")
}

// MARK: - Full album lifecycle: create → add a real photo → remove → delete

func albumFullTest() async {
    // 1) Create test album.
    let name = "⚠️TEST_DELETE_\(UUID().uuidString.prefix(8))"
    let created = await raw("SYNO.Foto.Browse.NormalAlbum", "create", [
        URLQueryItem(name: "name", value: name), URLQueryItem(name: "item", value: "[]"),
    ])
    guard let albumId = ((created?["data"] as? [String: Any])?["album"] as? [String: Any])?["id"] as? Int else {
        print("✘ create failed: \(created ?? [:])"); return
    }
    print("✓ created album id=\(albumId)")

    // 2) Grab one real photo id (we only add its album-membership; never modify it).
    let itemList = await raw("SYNO.Foto.Browse.Item", "list", [
        URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "1"),
        URLQueryItem(name: "sort_by", value: "takentime"), URLQueryItem(name: "sort_direction", value: "desc"),
    ])
    guard let photoId = ((itemList?["data"] as? [String: Any])?["list"] as? [[String: Any]])?.first?["id"] as? Int else {
        print("✘ couldn't get a photo id"); await deleteAlbum(albumId); return
    }
    print("  using real photo id=\(photoId) (membership only)")

    // 3) Probe add-item method.
    print("── add item to album")
    let addCandidates: [(String, String, [URLQueryItem])] = [
        ("SYNO.Foto.Browse.NormalAlbum", "add_item", [URLQueryItem(name: "id", value: "\(albumId)"), URLQueryItem(name: "item", value: "[\(photoId)]")]),
        ("SYNO.Foto.Browse.NormalAlbum", "add_item", [URLQueryItem(name: "album_id", value: "\(albumId)"), URLQueryItem(name: "item", value: "[\(photoId)]")]),
        ("SYNO.Foto.Browse.Album", "add_item", [URLQueryItem(name: "id", value: "\(albumId)"), URLQueryItem(name: "item", value: "[\(photoId)]")]),
    ]
    var addWorked = false
    for (api, method, query) in addCandidates {
        let resp = await raw(api, method, query)
        let ok = (resp?["success"] as? Bool) == true || (resp?["success"] as? Int) == 1
        print("   \(api) \(method): \(ok ? "✓" : "fail \(((resp?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "?")")")
        if ok { addWorked = true; break }
    }

    // 4) Verify album item_count.
    let countAfterAdd = await albumItemCount(albumId)
    print("   album item_count after add = \(countAfterAdd)")

    // 4a) Album cover structure (list with additional=["thumbnail"]).
    let withThumb = await raw("SYNO.Foto.Browse.Album", "list", [
        URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "100"),
        URLQueryItem(name: "additional", value: "[\"thumbnail\"]"),
    ])
    if let album = ((withThumb?["data"] as? [String: Any])?["list"] as? [[String: Any]])?.first(where: { ($0["id"] as? Int) == albumId }) {
        print("   album keys: \(album.keys.sorted().joined(separator: ", "))")
        if let add = album["additional"] as? [String: Any] {
            print("   additional keys: \(add.keys.sorted().joined(separator: ", "))")
            if let thumb = add["thumbnail"] as? [String: Any] {
                print("   thumbnail: \(thumb)")
            }
        }
    }

    // 4b) How do we list photos INSIDE an album?
    print("── list album items (probe)")
    for query in [
        [URLQueryItem(name: "album_id", value: "\(albumId)")],
        [URLQueryItem(name: "id", value: "\(albumId)")],
    ] {
        let resp = await raw("SYNO.Foto.Browse.Item", "list",
                             query + [URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "10")])
        let items = ((resp?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
        let code = ((resp?["error"] as? [String: Any])?["code"]).map { "\($0)" }
        print("   Browse.Item list \(query.first!.name)=\(albumId): items=\(items.count) \(code.map { "err=\($0)" } ?? "")")
    }

    // 5) Probe remove-item method.
    if addWorked {
        print("── remove item from album")
        let removeCandidates: [(String, String, [URLQueryItem])] = [
            ("SYNO.Foto.Browse.NormalAlbum", "delete_item", [URLQueryItem(name: "id", value: "\(albumId)"), URLQueryItem(name: "item", value: "[\(photoId)]")]),
            ("SYNO.Foto.Browse.NormalAlbum", "remove_item", [URLQueryItem(name: "id", value: "\(albumId)"), URLQueryItem(name: "item", value: "[\(photoId)]")]),
        ]
        for (api, method, query) in removeCandidates {
            let resp = await raw(api, method, query)
            let ok = (resp?["success"] as? Bool) == true || (resp?["success"] as? Int) == 1
            print("   \(api) \(method): \(ok ? "✓" : "fail \(((resp?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "?")")")
            if ok { break }
        }
        print("   album item_count after remove = \(await albumItemCount(albumId))")
    }

    // 6) Delete album (cleanup).
    await deleteAlbum(albumId)
}

func albumItemCount(_ albumId: Int) async -> Int {
    let list = await raw("SYNO.Foto.Browse.Album", "list", [
        URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "100"),
    ])
    let albums = ((list?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
    return albums.first { ($0["id"] as? Int) == albumId }?["item_count"] as? Int ?? -1
}

func deleteAlbum(_ albumId: Int) async {
    let resp = await raw("SYNO.Foto.Browse.Album", "delete", [URLQueryItem(name: "id", value: "[\(albumId)]")])
    let ok = (resp?["success"] as? Bool) == true || (resp?["success"] as? Int) == 1
    print("✓ deleted album id=\(albumId): \(ok)")
}

// MARK: - Find the album-delete method and clean up test albums

func cleanupTestAlbums() async {
    let list = await raw("SYNO.Foto.Browse.Album", "list", [
        URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "100"),
    ])
    let albums = ((list?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
    let testAlbums = albums.filter {
        let n = ($0["name"] as? String) ?? ""
        return n.contains("TEST") || n.contains("⚠️")
    }
    print("test albums to remove: \(testAlbums.map { "\($0["id"] as? Int ?? -1):\($0["name"] as? String ?? "")" })")

    for album in testAlbums {
        guard let id = album["id"] as? Int else { continue }
        // Probe candidate delete methods until one succeeds.
        let candidates: [(String, String, [URLQueryItem])] = [
            ("SYNO.Foto.Browse.Album", "delete", [URLQueryItem(name: "id", value: "[\(id)]")]),
            ("SYNO.Foto.Browse.NormalAlbum", "delete", [URLQueryItem(name: "id", value: "[\(id)]")]),
            ("SYNO.Foto.Browse.Album", "delete", [URLQueryItem(name: "id", value: "\(id)")]),
        ]
        for (api, method, query) in candidates {
            let resp = await raw(api, method, query)
            let ok = (resp?["success"] as? Bool) == true || (resp?["success"] as? Int) == 1
            print("   \(api) \(method) id=\(id): \(ok ? "✓ SUCCESS" : "fail \(((resp?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "?")")")
            if ok { break }
        }
    }
    // Confirm gone
    let after = await raw("SYNO.Foto.Browse.Album", "list", [
        URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "100"),
    ])
    let remaining = ((after?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
    let stillTest = remaining.filter { (($0["name"] as? String) ?? "").contains("TEST_DELETE") }
    print("remaining test albums: \(stillTest.compactMap { $0["id"] as? Int })")
}

// MARK: - Upload one synthetic image, then delete it

func makeTestJPEG() -> Data {
    let size = NSSize(width: 64, height: 64)
    let img = NSImage(size: size)
    img.lockFocus()
    NSColor.systemTeal.setFill()
    NSRect(origin: .zero, size: size).fill()
    img.unlockFocus()
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let jpeg = rep.representation(using: .jpeg, properties: [:]) else { return Data() }
    return jpeg
}

func uploadDeleteTest() async {
    // 1) Confirm the item-delete method EXISTS without deleting anything real
    //    (empty id list → method present but nothing to remove).
    for param in ["id", "unit_id"] {
        let resp = await raw("SYNO.Foto.Browse.Item", "delete", [URLQueryItem(name: param, value: "[]")])
        let code = ((resp?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "none"
        let ok = (resp?["success"] as? Bool) == true || (resp?["success"] as? Int) == 1
        print("── delete-method probe (\(param)=[]): success=\(ok) errorCode=\(code)")
    }

    // 2) Upload one synthetic test JPEG.
    let filename = "SYNOPHOTOS_TESTUPLOAD_\(UUID().uuidString.prefix(8)).jpg"
    let jpeg = makeTestJPEG()
    print("\n── Upload '\(filename)' (\(jpeg.count)B synthetic image)")

    let mtime = String(Int(Date().timeIntervalSince1970 * 1000))
    // From the captured web request: path is entry.cgi/SYNO.Foto.Upload.Item,
    // query has api/method/version=8; name/duplicate/mtime + file are multipart.
    let query = [
        URLQueryItem(name: "api", value: "SYNO.Foto.Upload.Item"),
        URLQueryItem(name: "method", value: "upload"),
        URLQueryItem(name: "version", value: "8"),
    ]
    // From the captured Payload: form-data values are JSON-encoded (strings
    // quoted, folder is an array, mtime a raw number). That was the missing bit.
    let uploadResp: [String: Any]? = await {
        guard let data = try? await client.requestMultipart(api: "SYNO.Foto.Upload.Item", extraQuery: query, pathSuffix: "SYNO.Foto.Upload.Item", build: { _, _ in
            let boundary = "----writespike\(UUID().uuidString)"
            var body = Data()
            func field(_ name: String, _ value: String) {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
                body.append("\(value)\r\n".data(using: .utf8)!)
            }
            field("api", "SYNO.Foto.Upload.Item")
            field("method", "upload")
            field("version", "8")
            field("uploadDestination", "\"timeline\"")
            field("duplicate", "\"ignore\"")
            field("name", "\"\(filename)\"")
            field("mtime", mtime)
            field("folder", "[\"PhotoLibrary\"]")
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append(jpeg)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
            return ("multipart/form-data; boundary=\(boundary)", body)
        }) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }()
    print("   upload response: \(uploadResp ?? [:])")

    let ok = (uploadResp?["success"] as? Bool) == true || (uploadResp?["success"] as? Int) == 1
    guard ok, let data = uploadResp?["data"] as? [String: Any] else {
        print("   ✘ upload failed — nothing to clean up (no file created)"); return
    }
    // The new item id (schema unknown — check common keys).
    let newId = data["id"] as? Int ?? data["item_id"] as? Int ?? (data["item"] as? [String: Any])?["id"] as? Int
    print("   ✓ upload OK, new item id=\(newId.map(String.init) ?? "unknown")")

    // 3) Delete the uploaded test item (by id).
    guard let newId else {
        print("   ⚠️ upload succeeded but id unknown — search by filename to clean up manually: \(filename)")
        return
    }
    print("── Delete uploaded test item id=\(newId)")
    for param in ["id", "unit_id"] {
        let resp = await raw("SYNO.Foto.Browse.Item", "delete", [URLQueryItem(name: param, value: "[\(newId)]")])
        let delOk = (resp?["success"] as? Bool) == true || (resp?["success"] as? Int) == 1
        print("   delete \(param)=[\(newId)]: \(delOk ? "✓ SUCCESS" : "fail \(((resp?["error"] as? [String: Any])?["code"]).map { "\($0)" } ?? "?")")")
        if delOk { break }
    }
}
