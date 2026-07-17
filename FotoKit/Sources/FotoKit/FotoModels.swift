import Foundation

// Models for SYNO.Foto.* responses. Field shapes are taken from real DSM
// responses captured in the Phase 0 spike (see spike/FINDINGS.md); decoded with
// a `.convertFromSnakeCase` JSONDecoder, so properties are camelCase.

public enum FotoMediaType: String, Decodable, Sendable {
    case photo, video
    // Unknown/future types decode as `.photo` rather than throwing.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FotoMediaType(rawValue: raw) ?? .photo
    }
}

/// A single photo or video. `time` is the taken-time (unix seconds).
public struct FotoItem: Decodable, Identifiable, Sendable {
    public let id: Int
    public let filename: String
    public let filesize: Int
    public let folderId: Int
    public let ownerUserId: Int
    public let time: Int
    public let indexedTime: Int
    public let type: FotoMediaType
    public let additional: FotoItemAdditional?
    /// Present only on the representative item of a similar-photos group (from
    /// `SYNO.Foto.Browse.SimilarItem list`). Its `itemId` roster lists every
    /// member of the group; `topPick` is Synology's recommended keeper.
    public let similar: FotoSimilarGroup?

    public var takenAt: Date { Date(timeIntervalSince1970: TimeInterval(time)) }

    /// Displayed width/height ratio (accounts for EXIF orientation) for the
    /// justified grid. 1.0 (square) when the resolution is unknown.
    public var aspectRatio: Double {
        guard let r = additional?.resolution, r.width > 0, r.height > 0 else { return 1 }
        var w = Double(r.width), h = Double(r.height)
        if let o = additional?.orientation, (5...8).contains(o) { swap(&w, &h) }
        return w / h
    }

    /// In the collapsed (SimilarItem) timeline, whether this row represents a
    /// stack of similar photos rather than a single one, and how many it holds.
    public var isStack: Bool { (similar?.count ?? 0) > 1 }
    public var stackCount: Int { max(similar?.count ?? 1, 1) }

    /// Whether the user has hearted this item (from `additional=["favorite"]`).
    public var isFavorite: Bool { additional?.favorite ?? false }
    /// Star rating 0–5 (from `additional=["rating"]`).
    public var rating: Int { additional?.rating ?? 0 }

    /// Video length in seconds (nil for photos or when video_meta wasn't loaded).
    public var videoDuration: TimeInterval? {
        guard type == .video, let ms = additional?.videoMeta?.duration, ms > 0 else { return nil }
        return TimeInterval(ms) / 1000
    }

    /// "m:ss" (or "h:mm:ss") label for a video's length, nil for photos.
    public var videoDurationLabel: String? {
        guard let seconds = videoDuration else { return nil }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// A group of visually-similar photos (bursts, near-duplicates) as identified by
/// Synology Photos. `topPick` is the server's recommended keeper.
public struct FotoSimilarGroup: Decodable, Sendable, Identifiable {
    public let id: Int
    public let count: Int
    public let itemId: [Int]
    public let topPick: Int

    /// The members to drop if the top pick is kept.
    public var removableIds: [Int] { itemId.filter { $0 != topPick } }
}

/// The signed-in Photos user (`SYNO.Foto.UserInfo me`). `isAdmin` is decoded
/// leniently (DSM returns it as a JSON bool that can arrive as 0/1).
public struct FotoUserInfo: Decodable, Sendable {
    public let id: Int
    public let uid: Int
    public let name: String
    public let isAdmin: Bool
    public let profile: Profile?

    public struct Profile: Decodable, Sendable {
        public let email: String?
        public let timezone: String?
        public let nickName: String?
    }

    private enum CodingKeys: String, CodingKey { case id, uid, name, isAdmin, profile }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        uid = (try? c.decode(Int.self, forKey: .uid)) ?? 0
        name = (try? c.decode(String.self, forKey: .name)) ?? "?"
        if let b = try? c.decode(Bool.self, forKey: .isAdmin) { isAdmin = b }
        else { isAdmin = ((try? c.decode(Int.self, forKey: .isAdmin)) ?? 0) != 0 }
        profile = try? c.decode(Profile.self, forKey: .profile)
    }
}

/// Indexing progress (`SYNO.Foto.Index get`). Each field is the number of items
/// still PENDING for that stage; 0 everywhere = fully indexed.
public struct FotoIndexStatus: Decodable, Sendable {
    public let basic: Int?
    public let thumbnail: Int?
    public let metadata: Int?
    public let faceExtraction: Int?
    public let personClustering: Int?
    public let conceptDetection: Int?
    public let geoCoding: Int?

    public var remaining: Int {
        [basic, thumbnail, metadata, faceExtraction, personClustering, conceptDetection, geoCoding]
            .compactMap { $0 }.reduce(0, +)
    }
    public var isComplete: Bool { remaining == 0 }
}

public struct FotoItemAdditional: Decodable, Sendable {
    public let thumbnail: FotoThumbnail?
    public let resolution: FotoResolution?
    public let orientation: Int?
    public let exif: FotoExif?
    public let gps: FotoGPS?
    public let address: FotoAddress?
    public let videoMeta: FotoVideoMeta?
    /// From `additional=["favorite","rating"]` (verified live). `favorite` is a
    /// JSON bool; `rating` is 0–5.
    public let favorite: Bool?
    public let rating: Int?
}

/// Video technical metadata (`additional=["video_meta"]`). `duration` is in
/// milliseconds. Present only for video items.
public struct FotoVideoMeta: Decodable, Sendable {
    public let duration: Int?
    public let resolutionX: Int?
    public let resolutionY: Int?
    public let videoCodec: String?
    public let framerate: Double?
}

/// The thumbnail descriptor. `cacheKey` changes with the item's version, so it
/// doubles as the cache-busting token for `SYNO.Foto.Thumbnail`.
public struct FotoThumbnail: Decodable, Sendable {
    public let cacheKey: String
    public let unitId: Int
    public let sm: String?
    public let m: String?
    public let xl: String?
    public let preview: String?

    public enum Size: String, Sendable { case sm, m, xl }

    /// Whether the given size has been generated on the server ("ready").
    public func isReady(_ size: Size) -> Bool {
        switch size {
        case .sm: return sm == "ready"
        case .m: return m == "ready"
        case .xl: return xl == "ready"
        }
    }
}

public struct FotoResolution: Decodable, Sendable {
    public let width: Int
    public let height: Int
}

public struct FotoExif: Decodable, Sendable {
    public let aperture: String?
    public let camera: String?
    public let exposureTime: String?
    public let focalLength: String?
    public let iso: String?
    public let lens: String?
}

public struct FotoGPS: Decodable, Sendable {
    public let latitude: Double
    public let longitude: Double
}

public struct FotoAddress: Decodable, Sendable {
    public let city: String?
    public let country: String?
    public let state: String?
    public let county: String?
    public let district: String?
    public let town: String?
    public let village: String?
    public let route: String?
    public let landmark: String?

    /// Readable location line (broad → specific), blanks and duplicates removed.
    public var displayLine: String {
        var parts: [String] = []
        for value in [country, state, city, county, district, town, village, route, landmark] {
            guard let v = value, !v.isEmpty, !parts.contains(v) else { continue }
            parts.append(v)
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Timeline

/// One day's item count in the timeline. The building block for the date
/// scrubber and section headers.
public struct FotoTimelineDay: Decodable, Sendable, Identifiable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let itemCount: Int

    public var id: Int { year * 10_000 + month * 100 + day }
    public var dateComponents: DateComponents { DateComponents(year: year, month: month, day: day) }
}

/// A server-paginated span of days (`offset`/`limit` are item indices within
/// the whole timeline, not day indices).
public struct FotoTimelineSection: Decodable, Sendable {
    public let offset: Int
    public let limit: Int
    public let list: [FotoTimelineDay]
}

// MARK: - Folder

public struct FotoFolder: Decodable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let parent: Int
    public let ownerUserId: Int
    public let shared: Bool

    /// Leaf name for display (DSM returns full paths like "/MobileBackup").
    public var displayName: String {
        let trimmed = name.hasSuffix("/") ? String(name.dropLast()) : name
        let leaf = (trimmed as NSString).lastPathComponent
        return leaf.isEmpty ? "/" : leaf
    }
}

// MARK: - Album

/// A normal (user-created) album. Schema from the Phase-0 write spike. Only the
/// fields the UI needs are decoded; DSM sends others (shared as 0/1, etc.) that
/// would break strict typing, so they're intentionally ignored.
public struct FotoAlbum: Decodable, Identifiable, Sendable, Hashable {
    public let id: Int
    public let name: String
    public let itemCount: Int
    /// Share token, present on albums created with `shared=true` (nil otherwise).
    public let passphrase: String?
    /// Cover thumbnail, present when listed with `additional=["thumbnail"]`.
    public let additional: FotoAlbumAdditional?

    // Hash by id only, so `additional` needn't be Hashable (NavigationLink).
    public static func == (lhs: FotoAlbum, rhs: FotoAlbum) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public struct FotoAlbumAdditional: Decodable, Sendable {
    public let thumbnail: FotoThumbnail?

    // An empty album's cover thumbnail can be present but lack `cache_key`, which
    // would otherwise break decoding of the whole album list — tolerate it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        thumbnail = try? c.decodeIfPresent(FotoThumbnail.self, forKey: .thumbnail)
    }
    private enum CodingKeys: String, CodingKey { case thumbnail }
}

// MARK: - Person (face recognition)

/// A face-recognition cluster from `SYNO.Foto.Browse.Person`. Named clusters
/// carry the user-assigned `name`; unnamed ones have an empty string. Schema
/// verified via the Phase-0 person probe: keys are id/name/item_count/cover/
/// additional/show (`show` intentionally not decoded).
public struct FotoPerson: Decodable, Identifiable, Sendable, Hashable {
    public let id: Int
    public let name: String
    public let itemCount: Int
    /// Unit id of the cover face; feeds `SYNO.Foto.Thumbnail` with `type=person`.
    public let cover: Int
    public let additional: FotoPersonAdditional?

    /// Display name, falling back to a placeholder for unnamed clusters.
    public var displayName: String { name.isEmpty ? "이름 없음" : name }
    public var isNamed: Bool { !name.isEmpty }

    // Hash by id only, so `additional` needn't be Hashable (NavigationLink).
    public static func == (lhs: FotoPerson, rhs: FotoPerson) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Person `additional.thumbnail` carries only a `cache_key` (the unit id comes
/// from the person's `cover`), unlike an item thumbnail.
public struct FotoPersonAdditional: Decodable, Sendable {
    public let thumbnail: FotoPersonThumbnail?
}

public struct FotoPersonThumbnail: Decodable, Sendable {
    public let cacheKey: String
}

// MARK: - Search suggestion (autocomplete)

/// One autocomplete suggestion from `SYNO.Foto.Search.Search suggest`. `type` is
/// the entity kind ("person", "place", "general_tag", …).
public struct FotoSearchSuggestion: Decodable, Sendable, Hashable, Identifiable {
    public let entityId: Int
    public let name: String
    public let type: String

    public var id: String { "\(type)#\(entityId)" }

    enum CodingKeys: String, CodingKey { case entityId = "id", name, type }
}

// MARK: - Sharing

/// A public share (Synology's album `sharing_info`). `sharingLink` is the ready
/// public URL; `privacyType` is "public-view" when live, "private" when off.
public struct FotoShare: Decodable, Sendable {
    public let passphrase: String?
    public let sharingLink: String?
    public let privacyType: String?
    public let enablePassword: Bool?
    public let expiration: Int?

    public var isPublic: Bool { privacyType == "public-view" }
    public var url: URL? { sharingLink.flatMap { URL(string: $0) } }
}

// MARK: - Place (geocoding) filter tree

/// A geocoding place node from `SYNO.Foto.Search.Filter list_in_similar`. `id` is
/// the value passed to `list_with_filter`'s `geocoding` param. Hierarchical:
/// country → city → district.
public struct FotoPlace: Decodable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let level: Int
    public let name: String
    public let children: [FotoPlace]

    /// This node + all descendants, flattened with their depth (0 = top).
    public func flattened(depth: Int = 0) -> [(place: FotoPlace, depth: Int)] {
        [(self, depth)] + children.flatMap { $0.flattened(depth: depth + 1) }
    }
}

/// A generic id/name filter option (camera, lens, ISO, aperture).
public struct FotoFilterOption: Decodable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let name: String
}

/// Available filter-facet values from `SYNO.Foto.Search.Filter list_in_similar`.
/// Each id feeds `filteredItems`'s matching param.
public struct FotoFilterFacets: Decodable, Sendable {
    public let camera: [FotoFilterOption]
    public let lens: [FotoFilterOption]
    public let iso: [FotoFilterOption]
    public let aperture: [FotoFilterOption]
    public let geocoding: [FotoPlace]

    public init(camera: [FotoFilterOption] = [], lens: [FotoFilterOption] = [],
                iso: [FotoFilterOption] = [], aperture: [FotoFilterOption] = [],
                geocoding: [FotoPlace] = []) {
        self.camera = camera; self.lens = lens; self.iso = iso
        self.aperture = aperture; self.geocoding = geocoding
    }
}

// MARK: - Response payload wrappers

public struct FotoItemListData: Decodable, Sendable { public let list: [FotoItem] }
public struct FotoCountData: Decodable, Sendable { public let count: Int }
public struct FotoTimelineData: Decodable, Sendable { public let section: [FotoTimelineSection] }
public struct FotoFolderData: Decodable, Sendable { public let folder: FotoFolder }
public struct FotoFolderListData: Decodable, Sendable { public let list: [FotoFolder] }
public struct FotoAlbumListData: Decodable, Sendable { public let list: [FotoAlbum] }
public struct FotoAlbumCreateData: Decodable, Sendable { public let album: FotoAlbum }
public struct FotoUploadData: Decodable, Sendable { public let id: Int }
public struct FotoPersonListData: Decodable, Sendable { public let list: [FotoPerson] }
public struct FotoSuggestListData: Decodable, Sendable { public let list: [FotoSearchSuggestion] }
public struct FotoGeocodingFilterData: Decodable, Sendable { public let geocoding: [FotoPlace] }
// Album.get with additional=["sharing_info"] → data.list[0].additional.sharing_info
public struct FotoAlbumGetData: Decodable, Sendable {
    public let list: [Album]
    public struct Album: Decodable, Sendable {
        public let additional: Additional?
        public struct Additional: Decodable, Sendable { public let sharingInfo: FotoShare? }
    }
}
