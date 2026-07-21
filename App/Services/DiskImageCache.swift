import Foundation
import CryptoKit

/// A small on-disk cache for thumbnail bytes, layered under the in-memory
/// `NSCache` in `ThumbnailLoader`. Thumbnails are content-addressed (the key
/// embeds the item's `cache_key`, which changes when a photo is edited), so
/// entries never go stale — they simply stop being requested and age out.
///
/// Files live in `Caches/` (the OS may reclaim them under pressure, which is
/// fine). A background sweep keeps the total under a byte budget by deleting the
/// least-recently-used files.
actor DiskImageCache {
    static let shared = DiskImageCache()

    private let directory: URL
    private let byteBudget: Int
    private var bytesSinceSweep = 0
    private var sweeping = false

    init(byteBudget: Int = 500 * 1024 * 1024) {
        self.byteBudget = byteBudget
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("SynologyPhotosManager/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name)
    }

    func data(for key: String) -> Data? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Touch mtime so the LRU sweep treats reads as recent use.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    func store(_ data: Data, for key: String) {
        try? data.write(to: fileURL(for: key), options: .atomic)
        // Re-sweep whenever writes accumulate past ~1/8 of the budget — not just
        // once per session. A long browsing session writes thousands of
        // thumbnails and would otherwise blow far past the budget after the
        // single initial sweep (which ran while the cache was still small).
        bytesSinceSweep += data.count
        if !sweeping, bytesSinceSweep >= max(byteBudget / 8, 32 * 1024 * 1024) {
            sweeping = true
            bytesSinceSweep = 0
            Task.detached(priority: .background) {
                self.sweepIfNeeded()
                await self.finishSweep()
            }
        }
    }

    private func finishSweep() { sweeping = false }

    /// Deletes least-recently-used files until the total is back under budget.
    /// `nonisolated` so the directory scan/deletes run off the actor and don't
    /// block concurrent thumbnail reads/writes (it only touches immutable
    /// `directory`/`byteBudget` and the filesystem).
    nonisolated private func sweepIfNeeded() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys) else { return }

        var entries: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let size = values?.fileSize ?? 0
            let date = values?.contentModificationDate ?? .distantPast
            entries.append((url, size, date))
            total += size
        }
        guard total > byteBudget else { return }

        for entry in entries.sorted(by: { $0.date < $1.date }) {
            guard total > byteBudget else { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    /// User-facing size of the cache on disk (bytes), for a Settings readout.
    func currentSize() -> Int {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return urls.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
