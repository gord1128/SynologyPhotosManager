import Foundation

/// A saved timeline-filter combination ("스마트 앨범" / saved search, à la Apple
/// Photos smart albums & Lightroom collections). It is NOT an AI feature and NOT
/// a server object — the NAS already did the recognition (people/places/concepts);
/// this just persists a rule over those facets + metadata and re-runs the app's
/// existing `filteredItems` browse. Pure-local (UserDefaults), so zero server risk.
struct SmartAlbumCriteria: Codable, Equatable {
    /// `LibraryViewModel.TypeFilter.rawValue` (전체/사진/동영상).
    var typeFilterRaw: String = "전체"
    var favoriteOnly: Bool = false
    var dateFilterActive: Bool = false
    var startDate: Date = .distantPast
    var endDate: Date = .now
    var personIds: [Int] = []
    /// `LibraryViewModel.PersonPolicy.rawValue` (아무나/모두).
    var personPolicyRaw: String = "아무나"
    var countryIds: [Int] = []
    var cameraIds: [Int] = []
    var lensIds: [Int] = []
    var isoIds: [Int] = []
    var apertureIds: [Int] = []
}

/// One named smart album. `isShared` scopes it to the space it was saved in —
/// the id-based facets (person_id, geocoding, camera…) are space-specific, so a
/// personal-space rule must never be applied in the shared space (that was bug
/// B1). The sidebar only surfaces albums matching the current space.
struct SmartAlbum: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var isShared: Bool
    var criteria: SmartAlbumCriteria
}

/// UserDefaults-backed persistence for smart albums (a small JSON blob).
enum SmartAlbumStore {
    private static let key = "smartAlbums"

    static func load() -> [SmartAlbum] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let albums = try? JSONDecoder().decode([SmartAlbum].self, from: data) else { return [] }
        return albums
    }

    static func save(_ albums: [SmartAlbum]) {
        guard let data = try? JSONEncoder().encode(albums) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
