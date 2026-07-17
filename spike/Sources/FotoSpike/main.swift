import Foundation
import CryptoKit
import AppKit
import SynoKit
import FotoKit

// Phase 0 spike — READ-ONLY. Discovers + calls SYNO.Foto.* against the real NAS
// using the credentials SynologyMonitor already stored, and saves each raw
// response to ./fixtures for schema-locking. No delete/write calls.

// MARK: - Reuse SynologyMonitor's stored credentials
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

let fixturesDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("fixtures")
try? FileManager.default.createDirectory(at: fixturesDir, withIntermediateDirectories: true)

let fotoAPIs = [
    "SYNO.API.Auth",
    "SYNO.Foto.Browse.Timeline",
    "SYNO.Foto.Browse.Item",
    "SYNO.Foto.Browse.Album",
    "SYNO.Foto.Browse.Folder",
    "SYNO.Foto.Thumbnail",
    "SYNO.Foto.Download",
]

let client = SynologyClient(connection: connection, sessionName: "FotoSpike")

func save(_ name: String, _ data: Data) {
    let url = fixturesDir.appendingPathComponent("\(name).json")
    // pretty-print if it's JSON, else raw
    if let obj = try? JSONSerialization.jsonObject(with: data),
       let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
        try? pretty.write(to: url)
    } else {
        try? data.write(to: url)
    }
}

/// Prints a shallow shape of a JSON response so schemas are visible in the log.
func sketch(_ data: Data, indent: String = "  ") -> String {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return "\(indent)<non-object: \(data.count) bytes>"
    }
    var lines: [String] = []
    let success = obj["success"] as? Bool ?? false
    lines.append("\(indent)success=\(success)")
    if let err = obj["error"] as? [String: Any] { lines.append("\(indent)error=\(err)") }
    if let d = obj["data"] as? [String: Any] {
        for (k, v) in d.sorted(by: { $0.key < $1.key }) {
            if let arr = v as? [Any] {
                lines.append("\(indent)data.\(k): [\(arr.count)]")
                if let first = arr.first as? [String: Any] {
                    lines.append("\(indent)  [0] keys: \(first.keys.sorted().joined(separator: ", "))")
                }
            } else {
                lines.append("\(indent)data.\(k): \(type(of: v))")
            }
        }
    }
    return lines.joined(separator: "\n")
}

func capture(_ label: String, api: String, method: String, version: Int? = nil, query: [URLQueryItem] = []) async {
    print("── \(label)  [\(api) \(method)]")
    do {
        let data = try await client.requestData(api: api, method: method, version: version, queryItems: query)
        save(label, data)
        print(sketch(data))
    } catch {
        print("  ERROR: \(error)")
    }
    print("")
}

do {
    // forceRefresh: don't reuse SynologyMonitor's cached (non-Foto) API map.
    let map = try await client.discoverAPIs(fotoAPIs, required: Set(fotoAPIs), forceRefresh: true)
    print("discovered Foto APIs: \(map.keys.filter { $0.contains("Foto") }.sorted().joined(separator: ", "))\n")

    try await client.login(username: connection.username, password: password)
    print("login OK, authenticated=\(client.isAuthenticated)\n")

    // --- READ-ONLY captures (best-guess methods/params per Synology conventions) ---

    // Timeline: probe method + param variants to find the working one.
    await capture("timeline_get", api: "SYNO.Foto.Browse.Timeline", method: "get")
    await capture("timeline_get_type", api: "SYNO.Foto.Browse.Timeline", method: "get", query: [
        URLQueryItem(name: "type", value: "day"),
    ])
    await capture("timeline_list", api: "SYNO.Foto.Browse.Timeline", method: "list")

    // Item list: probe additional-key sets (error 600 is likely an invalid key).
    let baseItemQuery = [
        URLQueryItem(name: "offset", value: "0"),
        URLQueryItem(name: "limit", value: "3"),
        URLQueryItem(name: "sort_by", value: "takentime"),
        URLQueryItem(name: "sort_direction", value: "desc"),
    ]
    await capture("item_list_minimal", api: "SYNO.Foto.Browse.Item", method: "list", query: baseItemQuery)
    await capture("item_list_thumb", api: "SYNO.Foto.Browse.Item", method: "list", query: baseItemQuery + [
        URLQueryItem(name: "additional", value: #"["thumbnail","resolution","orientation"]"#),
    ])
    await capture("item_list_rich", api: "SYNO.Foto.Browse.Item", method: "list", query: baseItemQuery + [
        URLQueryItem(name: "additional", value: #"["thumbnail","resolution","orientation","video_convert","video_meta","provider_user_id","exif","tag","gps","address"]"#),
    ])
    await capture("item_count", api: "SYNO.Foto.Browse.Item", method: "count")

    await capture("album_list", api: "SYNO.Foto.Browse.Album", method: "list", query: [
        URLQueryItem(name: "offset", value: "0"),
        URLQueryItem(name: "limit", value: "10"),
        URLQueryItem(name: "additional", value: #"["thumbnail"]"#),
        URLQueryItem(name: "sort_by", value: "create_time"),
        URLQueryItem(name: "sort_direction", value: "desc"),
    ])
    await capture("album_count", api: "SYNO.Foto.Browse.Album", method: "count")

    await capture("folder_root", api: "SYNO.Foto.Browse.Folder", method: "get", query: [
        URLQueryItem(name: "id", value: "0"),
    ])
    await capture("folder_list", api: "SYNO.Foto.Browse.Folder", method: "list", query: [
        URLQueryItem(name: "id", value: "0"),
        URLQueryItem(name: "offset", value: "0"),
        URLQueryItem(name: "limit", value: "10"),
    ])

    // Thumbnail: confirm the cache_key/unit_id mechanism (binary response).
    if let itemData = try? Data(contentsOf: fixturesDir.appendingPathComponent("item_list_thumb.json")),
       let obj = try? JSONSerialization.jsonObject(with: itemData) as? [String: Any],
       let list = (obj["data"] as? [String: Any])?["list"] as? [[String: Any]],
       let first = list.first,
       let add = first["additional"] as? [String: Any],
       let thumb = add["thumbnail"] as? [String: Any],
       let unitID = thumb["unit_id"], let cacheKey = thumb["cache_key"] {
        print("── thumbnail  [SYNO.Foto.Thumbnail get] unit_id=\(unitID) cache_key=\(cacheKey)")
        do {
            let data = try await client.requestData(api: "SYNO.Foto.Thumbnail", method: "get", queryItems: [
                URLQueryItem(name: "id", value: "\(unitID)"),
                URLQueryItem(name: "cache_key", value: "\(cacheKey)"),
                URLQueryItem(name: "type", value: "unit"),
                URLQueryItem(name: "size", value: "sm"),
            ])
            let isImage = data.starts(with: [0xFF, 0xD8]) || data.starts(with: [0x89, 0x50]) // JPEG/PNG
            print("  \(data.count) bytes, looksLikeImage=\(isImage)\n")
        } catch { print("  ERROR: \(error)\n") }
    }

    // Download probes (READ-ONLY: fetching bytes doesn't modify the NAS).
    if let itemData = try? Data(contentsOf: fixturesDir.appendingPathComponent("item_list_thumb.json")),
       let obj = try? JSONSerialization.jsonObject(with: itemData) as? [String: Any],
       let list = (obj["data"] as? [String: Any])?["list"] as? [[String: Any]],
       let first = list.first, let itemId = first["id"] {
        func kind(_ d: Data) -> String {
            if d.starts(with: [0x50, 0x4B]) { return "ZIP" }
            if d.starts(with: [0xFF, 0xD8]) { return "JPEG" }
            if d.count > 4, d[4...].starts(with: Array("ftyp".utf8)) { return "HEIC/MP4" }
            return d.count < 2000 ? "small(json/err)" : "binary"
        }
        print("── SYNO.Foto.Download probes for item \(itemId)")
        for param in ["item_id", "unit_id", "id"] {
            if let data = try? await client.requestData(api: "SYNO.Foto.Download", method: "download",
                                                        queryItems: [URLQueryItem(name: param, value: "[\(itemId)]")]) {
                print("   single \(param)=[\(itemId)]: \(data.count)B \(kind(data))")
            }
        }
        // multi-item (does it return a zip?)
        if let list2 = (obj["data"] as? [String: Any])?["list"] as? [[String: Any]], list2.count >= 2,
           let a = list2[0]["id"], let b = list2[1]["id"] {
            for param in ["item_id", "unit_id"] {
                if let data = try? await client.requestData(api: "SYNO.Foto.Download", method: "download",
                                                            queryItems: [URLQueryItem(name: param, value: "[\(a),\(b)]")]) {
                    print("   multi  \(param)=[\(a),\(b)]: \(data.count)B \(kind(data))")
                }
            }
        }
    }

    try? await client.logout()
    print("logged out. fixtures saved to \(fixturesDir.path)")

    // End-to-end through FotoKit.FotoService — the exact path the app's
    // LibraryViewModel + ThumbnailLoader use. Proves Phase 1 works for real.
    print("\n▶ FotoKit FotoService end-to-end")
    let svc = FotoService(connection: connection, space: .personal)
    try await svc.connect(username: connection.username, password: password)
    let sections = try await svc.timeline()
    print("  timeline sections: \(sections.count)  (first day items: \(sections.first?.list.first?.itemCount ?? 0))")
    print("  item count: \(try await svc.itemCount())")
    let items = try await svc.items(offset: 0, limit: 5)
    print("  items: \(items.count), first: \(items.first?.filename ?? "-")  type: \(items.first?.type.rawValue ?? "-")")
    let bigPage = try await svc.items(offset: 0, limit: 400)
    print("  items(limit:400) actually returned: \(bigPage.count)")
    if let first = items.first {
        let data = try await svc.thumbnailData(for: first, size: .m)
        let img = NSImage(data: data)
        print("  thumbnail: \(data.count) bytes → NSImage=\(img != nil) size=\(img.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "-")")
    }
    // Folder browsing: list root's subfolders + items inside one.
    let folders = try await svc.folders(parentId: 0)
    print("  folders under root: \(folders.count) → \(folders.map { "\($0.displayName)(id \($0.id))" }.joined(separator: ", "))")
    if let folder = folders.first {
        let fCount = try await svc.itemCount(inFolder: folder.id)
        let fItems = try await svc.items(inFolder: folder.id, offset: 0, limit: 3)
        print("  '\(folder.displayName)': count=\(fCount), sample=\(fItems.map(\.filename).prefix(2).joined(separator: ", "))")
        let sub = try await svc.folders(parentId: folder.id)
        print("  '\(folder.displayName)' subfolders: \(sub.count) → \(sub.prefix(4).map(\.displayName).joined(separator: ", "))")
    }
    // Which folder do actual photos live in?
    if let sample = try await svc.items(offset: 0, limit: 1).first {
        let fid = sample.folderId
        let inFolder = try await svc.itemCount(inFolder: fid)
        print("  sample photo '\(sample.filename)' folderId=\(fid) → itemCount(inFolder)=\(inFolder)")
        let subOfThat = try await svc.folders(parentId: fid)
        print("  folder \(fid) subfolders=\(subOfThat.count)")
    }
    if let first = items.first {
        let orig = try await svc.originalData(itemIds: [first.id])
        let magic = orig.count > 4 && orig[4...].starts(with: Array("ftyp".utf8)) ? "HEIC/MP4" : "\(orig.prefix(2).map { String(format: "%02X", $0) }.joined())"
        print("  originalData([\(first.id)]): \(orig.count)B (\(magic))")
    }

    // Streaming download to file (no memory buffering).
    if let first = items.first {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dl-\(UUID().uuidString).bin")
        try await svc.downloadOriginal(itemIds: [first.id], to: tmp)
        let size = ((try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.size] as? Int) ?? 0
        print("  downloadOriginal(to file): \(size)B written")
        try? FileManager.default.removeItem(at: tmp)
    }

    // Upload + delete round-trip through FotoService (synthetic image, cleaned up).
    func makeTestJPEG() -> Data {
        let size = NSSize(width: 48, height: 48)
        let img = NSImage(size: size)
        img.lockFocus(); NSColor.systemPink.setFill(); NSRect(origin: .zero, size: size).fill(); img.unlockFocus()
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [:]) else { return Data() }
        return jpeg
    }
    let countBefore = try await svc.itemCount()
    let uploadedId = try await svc.uploadItem(filename: "FOTOKIT_TEST_\(UUID().uuidString.prefix(6)).jpg", data: makeTestJPEG())
    print("  uploadItem → id=\(uploadedId)  (count \(countBefore)→\(try await svc.itemCount()))")
    try await svc.deleteItems(itemIds: [uploadedId])
    let countAfter = try await svc.itemCount()
    print("  deleteItems([\(uploadedId)]) OK  (count now \(countAfter), restored=\(countAfter == countBefore))")

    // Windowed-timeline alignment: does items(offset:) match the timeline's
    // cumulative day offsets? (If not, photos land in the wrong date section.)
    print("\n▶ Windowed alignment check")
    var dayOffsets: [(y: Int, m: Int, d: Int, base: Int)] = []
    var acc = 0
    for section in try await svc.timeline() {
        for day in section.list { dayOffsets.append((day.year, day.month, day.day, acc)); acc += day.itemCount }
    }
    print("  timeline total=\(acc), itemCount=\(try await svc.itemCount())")
    let cal = Calendar.current
    for off in [0, 200, 1000, 2000] where off < acc {
        guard let item = try await svc.items(offset: off, limit: 1).first,
              let day = dayOffsets.last(where: { $0.base <= off }) else { continue }
        let c = cal.dateComponents([.year, .month, .day], from: item.takenAt)
        let match = c.year == day.y && c.month == day.m && c.day == day.d
        print("  offset \(off): item \(c.year!)-\(c.month!)-\(c.day!) vs timeline \(day.y)-\(day.m)-\(day.d) \(match ? "✓" : "✗ MISALIGNED")")
    }

    await svc.disconnect()
    print("  FotoService E2E OK")

    // Cert-trust TOFU cycle — proves AppModel's untrusted→pin→reconnect logic.
    // Uses a throwaway store dir with the Photos-app namespace and NO pin.
    print("\n▶ Cert-trust TOFU cycle (temp store, no pin)")
    let certTmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("certtest-\(UUID().uuidString)")
    SecureLocalStore.directoryOverride = certTmp
    SecureLocalStore.serviceNamespace = "com.synokit"
    SecureLocalStore.legacyKeyProvider = nil
    do {
        let s1 = FotoService(connection: connection, space: .personal)
        try await s1.connect(username: connection.username, password: password)
        print("  (cert is system-trusted — connected without a pin; no prompt needed)")
        await s1.disconnect()
    } catch let SynologyAPIError.certificateUntrusted(host, port, fingerprint, certData) {
        print("  ✓ untrusted-cert challenge raised: \(host):\(port)  fp=\(fingerprint.prefix(20))…  \(certData.count)B")
        TrustedCertificateStore.pin(certificateData: certData, for: host, port: port)
        let s2 = FotoService(connection: connection, space: .personal)
        try await s2.connect(username: connection.username, password: password)
        print("  ✓ after pinning: reconnect authenticated=\(s2.isAuthenticated)")
        await s2.disconnect()
    } catch {
        print("  unexpected: \(error)")
    }
    SecureLocalStore.directoryOverride = nil
    try? FileManager.default.removeItem(at: certTmp)
} catch {
    print("SPIKE FAILED: \(error)")
    if case SynologyAPIError.otpRequired = error {
        print("→ account has 2FA; re-run with an OTP (spike would need an otp arg).")
    }
    exit(1)
}
