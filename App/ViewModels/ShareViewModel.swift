import Foundation
import Observation
import AppKit
import FotoKit

/// Drives the share sheet: creates a public share link for an album's photos
/// (Synology models this as a new shared album), copies it, or disables it.
@Observable
@MainActor
final class ShareViewModel {
    let service: FotoService
    let album: FotoAlbum

    private(set) var share: FotoShare?
    private(set) var sharedAlbumId: Int?
    private(set) var isWorking = false
    var errorMessage: String?

    var isShared: Bool { share?.isPublic ?? false }
    var linkURL: URL? { share?.url }

    init(service: FotoService, album: FotoAlbum) {
        self.service = service
        self.album = album
    }

    /// Creates the shared album + public link.
    func createLink() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let ids = (try? await service.items(inAlbum: album.id, offset: 0, limit: 5000))?.map(\.id) ?? []
            let result = try await service.createShareLink(name: album.name, itemIds: ids)
            share = result.share
            sharedAlbumId = result.albumId
        } catch {
            errorMessage = message(error)
        }
    }

    /// Disables the link by deleting the shared album (a separate copy — the
    /// original album is untouched). Avoids leaving orphaned shared albums.
    func disableLink() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            if let passphrase = share?.passphrase {
                try? await service.setSharePublic(passphrase: passphrase, enabled: false)
            }
            if let albumId = sharedAlbumId {
                try await service.deleteAlbums(ids: [albumId])
            }
            share = nil
            sharedAlbumId = nil
        } catch {
            errorMessage = message(error)
        }
    }

    func copyLink() {
        guard let url = linkURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
