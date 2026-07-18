import Foundation
import CryptoKit
import SynoKit

// T3 map-view spike — READ-ONLY. Answers "how do we efficiently collect photo
// coordinates for a map?" by measuring two strategies against the real NAS:
//   A) page every item requesting `additional=["gps"]` and filter client-side
//   B) use the geocoding facet as a cheap place index (counts without coords),
//      then fetch a place's photos on demand.
// No writes. Run: swift run MapSpike

// MARK: - Reuse SynologyMonitor's stored credentials (same as FotoSpike)
SecureLocalStore.appDirectoryName = "SynologyMonitor"
SecureLocalStore.serviceNamespace = "com.synologymonitor"
SecureLocalStore.legacyKeyProvider = {
    let seed = NSUserName() + ":com.synologymonitor.securelocalstore.v1"
    return SymmetricKey(data: SHA256.hash(data: Data(seed.utf8)))
}

guard let connection = CredentialStore.savedConnections().first,
      let password = CredentialStore.password(for: connection) else {
    print("no stored connection/password found"); exit(2)
}
print("NAS: \(connection.id)  user: \(connection.username)\n")

let client = SynologyClient(connection: connection, sessionName: "MapSpike")

// MARK: - JSON helpers (avoid strict model decoding — probe raw shapes)
func json(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}
func dataObj(_ data: Data) -> [String: Any] { (json(data)["data"] as? [String: Any]) ?? [:] }
func list(_ data: Data) -> [[String: Any]] { (dataObj(data)["list"] as? [[String: Any]]) ?? [] }
func pretty(_ obj: Any) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
          let s = String(data: d, encoding: .utf8) else { return "\(obj)" }
    return s
}

func hasGPS(_ item: [String: Any]) -> (Double, Double)? {
    guard let add = item["additional"] as? [String: Any],
          let gps = add["gps"] as? [String: Any],
          let lat = gps["latitude"] as? Double, let lon = gps["longitude"] as? Double,
          !(lat == 0 && lon == 0) else { return nil }
    return (lat, lon)
}

do {
    let apis = [
        "SYNO.API.Auth",
        "SYNO.Foto.Browse.Item",
        "SYNO.Foto.Search.Filter",
        "SYNO.Foto.Browse.SimilarItem",
    ]
    _ = try await client.discoverAPIs(apis, required: Set(apis), forceRefresh: true)
    try await client.login(username: connection.username, password: password)
    print("login OK, authenticated=\(client.isAuthenticated)\n")

    // Total item count (to extrapolate cost).
    let countData = try await client.requestData(api: "SYNO.Foto.Browse.Item", method: "count")
    let total = (dataObj(countData)["count"] as? Int) ?? -1
    print("── total items in library: \(total)\n")

    // ===== Probe A: page items with additional=["gps"], measure fill + cost =====
    print("===== PROBE A — GPS via item paging (additional=[\"gps\"]) =====")
    let pageSize = 500
    let maxPages = 6
    var offset = 0, pages = 0, seen = 0, geo = 0, bytes = 0
    var sampleCoords: [(Double, Double)] = []
    let t0 = Date()
    while pages < maxPages {
        let d = try await client.requestData(api: "SYNO.Foto.Browse.Item", method: "list", queryItems: [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(pageSize)),
            URLQueryItem(name: "sort_by", value: "takentime"),
            URLQueryItem(name: "sort_direction", value: "desc"),
            URLQueryItem(name: "additional", value: #"["gps"]"#),
        ])
        bytes += d.count
        let items = list(d)
        if items.isEmpty { break }
        seen += items.count
        for it in items { if let c = hasGPS(it) { geo += 1; if sampleCoords.count < 3 { sampleCoords.append(c) } } }
        offset += items.count; pages += 1
        if items.count < pageSize { break }
    }
    let dtA = Date().timeIntervalSince(t0)
    let fill = seen > 0 ? Double(geo) / Double(seen) : 0
    let bytesPerItem = seen > 0 ? bytes / seen : 0
    print(String(format: "  paged %d items in %d pages (%.2fs) — %d have GPS (%.0f%% fill)", seen, pages, dtA, geo, fill * 100))
    print(String(format: "  payload: %d bytes total, ~%d B/item (additional=[gps])", bytes, bytesPerItem))
    if total > 0 && seen > 0 {
        let estBytes = bytesPerItem * total
        let estTime = dtA / Double(seen) * Double(total)
        print(String(format: "  EXTRAPOLATE full library (%d items): ~%.1f MB, ~%.1fs to page all",
                     total, Double(estBytes) / 1_048_576, estTime))
        print(String(format: "  → est. geolocated photos: ~%d", Int(Double(total) * fill)))
    }
    print("  sample coords: \(sampleCoords)\n")

    // ===== Probe B: geocoding facet as a place index (counts w/o coords) =====
    print("===== PROBE B — geocoding facet (Search.Filter list_in_similar) =====")
    let setting = "{\"geocoding\":true,\"camera\":false,\"lens\":false,\"iso\":false,\"aperture\":false,\"item_type\":false,\"time\":false,\"person\":false,\"favorite\":false,\"rating\":false,\"flash\":false,\"focal_length_group\":false,\"exposure_time_group\":false,\"general_tag\":false}"
    let facetData = try await client.requestData(api: "SYNO.Foto.Search.Filter", method: "list_in_similar", version: 4, queryItems: [
        URLQueryItem(name: "setting", value: setting),
        URLQueryItem(name: "additional", value: #"["thumbnail"]"#),
    ])
    let facetObj = dataObj(facetData)
    let geocoding = (facetObj["geocoding"] as? [[String: Any]]) ?? []
    print("  geocoding top-level nodes: \(geocoding.count)")
    // Show the raw shape of ONE node (to learn if it carries a count).
    if let first = geocoding.first {
        print("  node[0] keys: \(first.keys.sorted().joined(separator: ", "))")
        print("  node[0] raw:\n\(pretty(first).split(separator: "\n").prefix(24).joined(separator: "\n"))")
    }
    // Walk the tree; print name + any count-like field + child count.
    func walk(_ nodes: [[String: Any]], depth: Int) {
        for n in nodes {
            let name = (n["name"] as? String) ?? "?"
            let id = (n["id"] as? Int).map(String.init) ?? "?"
            let cnt = (n["item_count"] as? Int) ?? (n["count"] as? Int)
            let kids = (n["children"] as? [[String: Any]]) ?? []
            let pad = String(repeating: "  ", count: depth + 1)
            print("\(pad)[\(id)] \(name)  count=\(cnt.map(String.init) ?? "—")  children=\(kids.count)")
            if depth < 1 { walk(kids, depth: depth + 1) }   // 2 levels deep only
        }
    }
    walk(geocoding, depth: 0)
    print("")

    // ===== Probe C: fetch one place's photos w/ coords on demand =====
    print("===== PROBE C — one place's photos via list_with_filter geocoding=[id] =====")
    if let firstId = geocoding.first?["id"] as? Int {
        let d = try await client.requestData(api: "SYNO.Foto.Browse.SimilarItem", method: "list_with_filter", version: 2, queryItems: [
            URLQueryItem(name: "item_type", value: "[0,1]"),
            URLQueryItem(name: "geocoding", value: "[\(firstId)]"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: "8"),
            URLQueryItem(name: "additional", value: #"["gps","thumbnail","address"]"#),
        ])
        let items = list(d)
        let withGPS = items.compactMap { hasGPS($0) }
        print("  place id=\(firstId): returned \(items.count) items, \(withGPS.count) with GPS")
        print("  coords: \(withGPS.prefix(5))")
        if let a0 = items.first?["additional"] as? [String: Any], let addr = a0["address"] as? [String: Any] {
            print("  sample address keys: \(addr.keys.sorted().joined(separator: ", "))")
        }
    } else {
        print("  (no geocoding nodes to sample)")
    }
    print("\n✅ MapSpike done — see numbers above for the T3 strategy decision.")
} catch {
    print("ERROR: \(error)")
    exit(1)
}
