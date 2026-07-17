import Foundation
import AppKit
import FotoKit

/// Loads + caches Synology Photos thumbnails. Keyed by the item's `unit_id` +
/// `cache_key` (the latter changes with the item version, so cached images
/// invalidate automatically when a photo is edited server-side). De-duplicates
/// concurrent requests for the same thumbnail.
actor ThumbnailLoader {
    private let service: FotoService
    private let cache = NSCache<NSString, NSImage>()
    private let disk = DiskImageCache.shared
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    init(service: FotoService) {
        self.service = service
        cache.countLimit = 800
    }

    private func key(_ thumb: FotoThumbnail, _ size: FotoThumbnail.Size) -> String {
        "\(thumb.unitId)_\(thumb.cacheKey)_\(size.rawValue)"
    }

    func image(for item: FotoItem, size: FotoThumbnail.Size = .m) async -> NSImage? {
        guard let thumb = item.additional?.thumbnail else { return nil }
        return await image(thumbnail: thumb, size: size)
    }

    /// Loads by a thumbnail descriptor directly (e.g. an album cover). If the
    /// requested size isn't marked ready, falls back to any other ready size
    /// rather than showing a permanent blank; if none is flagged ready, still
    /// attempts the requested size (the flag can be stale/conservative).
    func image(thumbnail thumb: FotoThumbnail, size: FotoThumbnail.Size = .m) async -> NSImage? {
        let fetchSize = resolveSize(thumb, preferred: size)
        let k = key(thumb, fetchSize)
        if let cached = cache.object(forKey: k as NSString) { return cached }
        if let existing = inFlight[k] { return await existing.value }

        let task = Task<NSImage?, Never> { [service, disk] in
            if let cached = await disk.data(for: k), let img = NSImage(data: cached) { return img }
            guard let data = try? await service.thumbnailData(unitId: thumb.unitId, cacheKey: thumb.cacheKey, size: fetchSize),
                  let img = NSImage(data: data) else { return nil }
            await disk.store(data, for: k)
            return img
        }
        inFlight[k] = task
        let image = await task.value
        inFlight[k] = nil
        if let image { cache.setObject(image, forKey: k as NSString) }
        return image
    }

    /// Prefer the requested size; else the best ready size; else request anyway.
    private func resolveSize(_ thumb: FotoThumbnail, preferred: FotoThumbnail.Size) -> FotoThumbnail.Size {
        if thumb.isReady(preferred) { return preferred }
        for candidate: FotoThumbnail.Size in [.m, .xl, .sm] where thumb.isReady(candidate) { return candidate }
        return preferred
    }

    /// A person's tight face crop for the People grid (`type=person` keyed by the
    /// PERSON id — verified to return a real crop for every person, matching the
    /// web). Cascades sizes for robustness.
    func image(forPerson person: FotoPerson, size: FotoThumbnail.Size = .sm) async -> NSImage? {
        guard let cacheKey = person.additional?.thumbnail?.cacheKey else { return nil }
        let k = "person_\(person.id)_\(cacheKey)_\(size.rawValue)"
        if let cached = cache.object(forKey: k as NSString) { return cached }
        if let existing = inFlight[k] { return await existing.value }

        let task = Task<NSImage?, Never> { [service, disk] in
            if let cached = await disk.data(for: k), let img = NSImage(data: cached) { return img }
            for s: FotoThumbnail.Size in [size, .m, .xl] {
                if let data = try? await service.personFaceCropData(personId: person.id, cacheKey: cacheKey, size: s),
                   let img = NSImage(data: data) {
                    await disk.store(data, for: k)
                    return img
                }
            }
            return nil
        }
        inFlight[k] = task
        let image = await task.value
        inFlight[k] = nil
        if let image { cache.setObject(image, forKey: k as NSString) }
        return image
    }
}
