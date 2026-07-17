import Foundation
import Observation
import FotoKit

/// Drives the albums screen: list + create + delete. One instance per connected
/// service (recreated on connection/space change).
@Observable
@MainActor
final class AlbumsViewModel {
    let service: FotoService
    let thumbnailLoader: ThumbnailLoader

    private(set) var albums: [FotoAlbum] = []
    private(set) var isLoading = false
    var errorMessage: String?

    private var loadedOnce = false

    init(service: FotoService) {
        self.service = service
        self.thumbnailLoader = ThumbnailLoader(service: service)
    }

    func loadIfNeeded() async {
        guard !loadedOnce else { return }
        loadedOnce = true
        await reload()
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            albums = try await service.albums()
            errorMessage = nil
        } catch {
            // Clear so stale (e.g. personal-space) albums don't linger after a
            // failed shared-space fetch.
            albums = []
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func createAlbum(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await service.createAlbum(name: trimmed)
            await reload()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func rename(_ album: FotoAlbum, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != album.name else { return }
        do {
            try await service.renameAlbum(id: album.id, name: trimmed)
            await reload()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func delete(_ album: FotoAlbum) async {
        do {
            try await service.deleteAlbums(ids: [album.id])
            await reload()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
