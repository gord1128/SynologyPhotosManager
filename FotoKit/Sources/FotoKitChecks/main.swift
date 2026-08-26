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


// MARK: - Lenient decoding (BUG: one odd row used to kill the whole page)

checks.section("Lenient decoding")

// A page whose rows are: (1) complete, (2) missing every optional-ish field,
// (3) unusable (no id). Strictly decoded this threw and the user got an empty
// grid for a library that is almost entirely fine.
let mixedPage = Data("""
{"success":true,"data":{"list":[
  {"id":11,"filename":"good.jpg","filesize":100,"folder_id":3,"owner_user_id":1,"time":1700000000,"indexed_time":1700000001,"type":"photo"},
  {"id":12,"indexed_time":1600000000},
  {"filename":"no-id.jpg","type":"photo"}
]}}
""".utf8)

do {
    let env = try decoder.decode(DSMEnvelope<FotoItemListData>.self, from: mixedPage)
    let list = env.data?.list ?? []
    checks.expectEqual(list.count, 2, "id 있는 두 줄은 살아남고 id 없는 줄만 버려진다")
    checks.expect(list.first?.filename == "good.jpg", "정상 항목은 그대로 디코딩된다")
    let sparse = list.first { $0.id == 12 }
    checks.expect(sparse != nil, "필드가 대부분 빠진 항목도 살아남는다")
    checks.expect(sparse?.filename == "이름 없음", "빠진 filename은 자리표로 대체된다")
    checks.expectEqual(sparse?.filesize ?? -1, 0, "빠진 filesize는 0")
    checks.expectEqual(sparse?.type ?? .video, .photo, "빠진 type은 사진으로 본다")
    // 촬영일이 없으면 색인 시각으로 — 0이면 1970년 섹션에 몰린다.
    checks.expectEqual(sparse?.time ?? -1, 1600000000, "빠진 time은 indexed_time으로 대체된다")
} catch {
    checks.expect(false, "관대 디코딩이 여전히 throw한다: \(error)")
}

// 망가진 gps 하나가 썸네일까지 앗아가면 그리드가 빈 칸이 된다.
let badGPS = Data("""
{"success":true,"data":{"list":[
  {"id":21,"filename":"a.jpg","filesize":1,"folder_id":1,"owner_user_id":1,"time":1,"indexed_time":1,"type":"photo",
   "additional":{"thumbnail":{"cache_key":"21_1","unit_id":21,"sm":"ready"},"gps":{"latitude":"북위 37도","longitude":127.0}}}
]}}
""".utf8)

do {
    let env = try decoder.decode(DSMEnvelope<FotoItemListData>.self, from: badGPS)
    let item = env.data?.list.first
    checks.expectEqual(env.data?.list.count ?? -1, 1, "additional 일부가 망가져도 항목은 남는다")
    checks.expect(item?.additional?.thumbnail?.cacheKey == "21_1", "망가진 gps 옆의 thumbnail은 보존된다")
    checks.expect(item?.additional?.gps == nil, "망가진 gps만 버려진다")
} catch {
    checks.expect(false, "additional 관대 디코딩이 throw한다: \(error)")
}

// 패싯 하나가 없다고 필터 패널 전체가 비면 안 된다.
let partialFacets = Data("""
{"success":true,"data":{"camera":[{"id":1,"name":"ILCE-7M4"}],"iso":[],"aperture":[],
 "geocoding":[{"id":9,"level":1,"name":"대한민국","children":[{"id":10,"level":2,"name":"서울"},{"level":2}]}]}}
""".utf8)

do {
    let env = try decoder.decode(DSMEnvelope<FotoFilterFacets>.self, from: partialFacets)
    let facets = env.data
    checks.expectEqual(facets?.camera.count ?? -1, 1, "lens 키가 없어도 camera 패싯은 살아 있다")
    checks.expectEqual(facets?.lens.count ?? -1, 0, "없는 패싯은 빈 배열")
    checks.expectEqual(facets?.geocoding.first?.children.count ?? -1, 1, "id 없는 하위 장소만 버려진다")
} catch {
    checks.expect(false, "패싯 관대 디코딩이 throw한다: \(error)")
}

// 유사 사진 묶음이 망가져도 대표 사진은 타임라인에 남아야 한다.
let badSimilar = Data("""
{"success":true,"data":{"list":[
  {"id":31,"filename":"burst.jpg","filesize":1,"folder_id":1,"owner_user_id":1,"time":1,"indexed_time":1,"type":"photo",
   "similar":{"id":5,"item_id":[31,32,33]}}
]}}
""".utf8)

do {
    let env = try decoder.decode(DSMEnvelope<FotoItemListData>.self, from: badSimilar)
    let item = env.data?.list.first
    checks.expectEqual(env.data?.list.count ?? -1, 1, "similar가 불완전해도 항목은 남는다")
    checks.expectEqual(item?.similar?.count ?? -1, 3, "빠진 count는 로스터 길이로 채운다")
    checks.expectEqual(item?.similar?.topPick ?? -1, 31, "빠진 top_pick은 첫 구성원")
} catch {
    checks.expect(false, "similar 관대 디코딩이 throw한다: \(error)")
}


// MARK: - Upload envelope (스트리밍 전환: 바이트가 그대로인가)

checks.section("Upload multipart envelope")

do {
    // 업로드 API까지 discovery에 포함시킨 핸들러
    let uploadInfo = #"""
    {"success":true,"data":{
     "SYNO.API.Auth":{"path":"entry.cgi","minVersion":1,"maxVersion":7},
     "SYNO.Foto.Upload.Item":{"path":"entry.cgi","minVersion":1,"maxVersion":8}
    }}
    """#
    StubURLProtocol.setHandler { request in
        let url = request.url?.absoluteString ?? ""
        if url.contains("SYNO.API.Info") { return (200, uploadInfo.data(using: .utf8)!) }
        // 로그인도 업로드도 POST다. 로그인은 자격증명을 폼 본문에 담아 URL에 아무
        // 질의도 없이 가므로, 업로드 경로(_sid + Upload.Item)로 갈라야 한다.
        if !url.contains("Upload.Item") { return (200, #"{"success":true,"data":{"sid":"SID"}}"#.data(using: .utf8)!) }
        return (200, #"{"success":true,"data":{"id":4242}}"#.data(using: .utf8)!)
    }

    // 경계를 넘길 만큼 큰 파일(청크 8MB보다 크게)에 표식을 앞뒤로 박는다.
    let head = Data("HEAD-MARKER".utf8)
    let filler = Data(repeating: 0xAB, count: 9 * 1024 * 1024)
    let tail = Data("TAIL-MARKER".utf8)
    let payload = head + filler + tail
    let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("업로드 시험.jpg")
    try payload.write(to: tmpFile)
    defer { try? FileManager.default.removeItem(at: tmpFile) }
    // mtime을 명시해 폼 필드까지 확인한다.
    let when = Date(timeIntervalSince1970: 1_600_000_000)
    try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: tmpFile.path)

    // 호스트를 달리해 새 캐시 키를 쓴다. APIInfoCache는 디스크 파일을 인스턴스끼리
    // 공유하므로, 같은 호스트를 쓰면 앞선 검사가 저장한 (Upload.Item이 없는) 맵이
    // 그대로 되살아난다 — 실제로 이 검사가 그렇게 한 번 실패했다.
    let uploadConn = NASConnection(host: "upload.test", port: 5001, username: "me")
    let uploadClient = SynologyClient(
        connection: uploadConn, session: StubURLProtocol.makeSession(),
        trustDelegate: CertificateTrustDelegate(host: uploadConn.host, port: uploadConn.port),
        apiInfoCache: APIInfoCache())
    let svc = FotoService(client: uploadClient, space: .personal)
    try await svc.connect(username: "me", password: "pw")
    let newID = try await svc.uploadItem(fileURL: tmpFile)
    checks.expectEqual(newID, 4242, "업로드 응답의 새 항목 id를 돌려준다")

    guard let body = StubURLProtocol.lastRequestBody,
          let contentType = StubURLProtocol.lastContentType else {
        checks.expect(false, "업로드 본문을 잡지 못했다"); throw FotoError.notConfigured
    }

    // 1) Content-Type의 boundary와 본문의 구분자가 일치하는가
    let boundary = contentType.components(separatedBy: "boundary=").last ?? ""
    checks.expect(!boundary.isEmpty, "Content-Type에 boundary가 있다")
    let bodyText = String(decoding: body.prefix(2048), as: UTF8.self)
    checks.expect(bodyText.hasPrefix("--\(boundary)\r\n"), "본문이 헤더의 boundary로 시작한다")

    // 2) DSM이 요구하는 폼 필드(JSON 인용 포함)가 그대로인가
    checks.expect(bodyText.contains("name=\"api\"\r\n\r\nSYNO.Foto.Upload.Item\r\n"), "api 필드")
    checks.expect(bodyText.contains("name=\"uploadDestination\"\r\n\r\n\"timeline\"\r\n"), "uploadDestination은 따옴표째")
    checks.expect(bodyText.contains("name=\"folder\"\r\n\r\n[\"PhotoLibrary\"]\r\n"), "folder는 배열 리터럴")
    checks.expect(bodyText.contains("name=\"mtime\"\r\n\r\n1600000000\r\n"), "mtime은 파일의 수정 시각에서 온다")
    checks.expect(bodyText.contains("filename=\"업로드 시험.jpg\""), "파일 이름은 JSON 인용되어 들어간다")

    // 3) 파일 바이트가 손상 없이, 정확히 한 번 들어갔는가
    checks.expect(body.range(of: head) != nil && body.range(of: tail) != nil, "파일의 처음과 끝 표식이 본문에 있다")
    let terminator = Data("\r\n--\(boundary)--\r\n".utf8)
    checks.expect(body.suffix(terminator.count) == terminator, "본문이 종료 구분자로 끝난다")
    // 봉투 = 머리말 + 파일 + 꼬리말. 파일 바이트가 한 벌만 들어갔는지 길이로 확인한다.
    let overhead = body.count - payload.count
    checks.expect(overhead > 0 && overhead < 4096, "파일 외 오버헤드는 머리말/꼬리말뿐 (\(overhead) 바이트)")
    // 청크 경계(8MB)에서 잘리거나 겹치지 않았는가
    let fileStart = body.range(of: head)!.lowerBound
    let extracted = body[fileStart..<(fileStart + payload.count)]
    checks.expect(Data(extracted) == payload, "9MB 파일이 청크 경계를 넘어 바이트 단위로 동일하다")
} catch {
    checks.expect(false, "업로드 봉투 검사가 throw했다: \(error)")
}

StubURLProtocol.setHandler(nil)
checks.finish()
