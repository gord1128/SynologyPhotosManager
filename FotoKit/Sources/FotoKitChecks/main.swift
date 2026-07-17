import Foundation
import SynoKit
import FotoKit

let checks = Checks()

let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return d
}()

func fixture(_ name: String) -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
          let data = try? Data(contentsOf: url) else {
        print("missing fixture: \(name)"); exit(2)
    }
    return data
}

// MARK: - Decode real captured responses

checks.section("Decode real DSM fixtures")

do {
    let env = try decoder.decode(DSMEnvelope<FotoTimelineData>.self, from: fixture("timeline_get"))
    let sections = env.data?.section ?? []
    checks.expectEqual(sections.count, 21, "timeline: 21 sections decoded")
    let firstDay = sections.first?.list.first
    checks.expect(firstDay?.year == 2026 && firstDay?.month == 7 && firstDay?.day == 10, "timeline first day = 2026-07-10")
    checks.expectEqual(firstDay?.itemCount ?? -1, 83, "timeline first day item_count = 83")
    checks.expectEqual(firstDay?.id ?? 0, 20260710, "timeline day id encodes yyyymmdd")
} catch { checks.expect(false, "timeline decode threw: \(error)") }

do {
    let env = try decoder.decode(DSMEnvelope<FotoItemListData>.self, from: fixture("item_list_rich"))
    let item = env.data?.list.first
    checks.expectEqual(item?.id ?? -1, 4598, "item id = 4598")
    checks.expectEqual(item?.type ?? .video, .photo, "item type = photo")
    checks.expect(item?.filename == "IMG_SAMPLE_0001.HEIC", "item filename decoded")
    let add = item?.additional
    checks.expectEqual(add?.thumbnail?.cacheKey ?? "", "4598_1783667422", "thumbnail cacheKey decoded")
    checks.expectEqual(add?.thumbnail?.unitId ?? -1, 4598, "thumbnail unitId decoded")
    checks.expect(add?.thumbnail?.isReady(.sm) == true, "thumbnail sm is ready")
    checks.expect(add?.resolution?.width == 4284 && add?.resolution?.height == 5712, "resolution decoded")
    checks.expect(add?.exif?.camera == "iPhone 17", "exif camera decoded")
    checks.expect((add?.gps?.latitude ?? 0) > 12 && (add?.gps?.latitude ?? 0) < 13, "gps latitude decoded")
    checks.expect(add?.address?.city == "샘플시", "address city decoded (localized unicode)")
} catch { checks.expect(false, "item decode threw: \(error)") }

do {
    let env = try decoder.decode(DSMEnvelope<FotoFolderListData>.self, from: fixture("folder_list"))
    let folder = env.data?.list.first
    checks.expect(folder?.name == "/MobileBackup", "folder full path decoded")
    checks.expectEqual(folder?.displayName ?? "", "MobileBackup", "folder displayName is leaf")
    let root = try decoder.decode(DSMEnvelope<FotoFolderData>.self, from: fixture("folder_root")).data?.folder
    checks.expect(root?.name == "/" && root?.id == 2, "root folder decoded")
} catch { checks.expect(false, "folder decode threw: \(error)") }

// MARK: - FotoService over a stubbed transport

checks.section("FotoService (stubbed)")

let connection = NASConnection(host: "nas.test", port: 5001, username: "me")

func makeService(space: FotoSpace) -> FotoService {
    let session = StubURLProtocol.makeSession()
    let delegate = CertificateTrustDelegate(host: connection.host, port: connection.port)
    let client = SynologyClient(connection: connection, session: session, trustDelegate: delegate, apiInfoCache: APIInfoCache())
    return FotoService(client: client, space: space)
}

// One handler serves discovery + login + browse; records which api was hit.
let infoData = #"""
{"success":true,"data":{
 "SYNO.API.Auth":{"path":"entry.cgi","minVersion":1,"maxVersion":7},
 "SYNO.Foto.Browse.Item":{"path":"entry.cgi","minVersion":1,"maxVersion":7},
 "SYNO.Foto.Browse.Timeline":{"path":"entry.cgi","minVersion":1,"maxVersion":6},
 "SYNO.FotoTeam.Browse.Item":{"path":"entry.cgi","minVersion":1,"maxVersion":7},
 "SYNO.FotoTeam.Browse.Timeline":{"path":"entry.cgi","minVersion":1,"maxVersion":6}
}}
"""#

func installHandler() {
    let timelineFixture = fixture("timeline_get")
    let itemFixture = fixture("item_list_rich")
    StubURLProtocol.setHandler { request in
        let url = request.url?.absoluteString ?? ""
        if url.contains("SYNO.API.Info") { return (200, infoData.data(using: .utf8)!) }
        if request.httpMethod == "POST" { return (200, #"{"success":true,"data":{"sid":"SID"}}"#.data(using: .utf8)!) }
        if url.contains("Timeline") { return (200, timelineFixture) }
        return (200, itemFixture)
    }
}

// Personal space routes to SYNO.Foto.*
do {
    installHandler()
    let svc = makeService(space: .personal)
    try await svc.connect(username: "me", password: "pw")
    let sections = try await svc.timeline()
    checks.expectEqual(sections.count, 21, "service.timeline returns sections")
    checks.expect(StubURLProtocol.lastRequestURL?.absoluteString.contains("SYNO.Foto.Browse.Timeline") == true, "personal space → SYNO.Foto.Browse.Timeline")

    let items = try await svc.items(offset: 0, limit: 3)
    checks.expect(items.first?.id == 4598, "service.items decodes items")
    let itemURL = StubURLProtocol.lastRequestURL?.absoluteString ?? ""
    checks.expect(itemURL.contains("SYNO.Foto.Browse.Item"), "personal space → SYNO.Foto.Browse.Item")
    checks.expect(!itemURL.contains("person"), "items additional excludes invalid 'person' key")
} catch { checks.expect(false, "personal service flow threw: \(error)") }

// Shared space routes to SYNO.FotoTeam.*
do {
    installHandler()
    let svc = makeService(space: .shared)
    try await svc.connect(username: "me", password: "pw")
    _ = try await svc.timeline()
    checks.expect(StubURLProtocol.lastRequestURL?.absoluteString.contains("SYNO.FotoTeam.Browse.Timeline") == true, "shared space → SYNO.FotoTeam.Browse.Timeline")
} catch { checks.expect(false, "shared service flow threw: \(error)") }

// Foto error mapping
checks.section("Foto error mapping")
checks.expect((FotoError.from(600) as? FotoError).map { if case .invalidParameter = $0 { return true }; return false } == true, "600 → invalidParameter")
checks.expect((FotoError.from(103) as? FotoError).map { if case .methodNotFound = $0 { return true }; return false } == true, "103 → methodNotFound")
checks.expect((FotoError.from(105) as? SynologyAPIError).map { if case .sessionExpired = $0 { return true }; return false } == true, "session code 105 → sessionExpired")

StubURLProtocol.setHandler(nil)
checks.finish()
