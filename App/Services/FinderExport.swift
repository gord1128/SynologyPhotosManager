import Foundation
import UniformTypeIdentifiers
import FotoKit

/// Builds an `NSItemProvider` that lazily downloads a photo's ORIGINAL and hands
/// Finder a real file — so dragging a thumbnail out of the grid exports it
/// ("꺼내기" in one drag, plan D2). The download only runs if/when the drop is
/// accepted, streamed to a temp file the system then copies.
enum FinderExport {
    static func itemProvider(for item: FotoItem, service: FotoService) -> NSItemProvider {
        let provider = NSItemProvider()
        let filename = item.filename
        let ext = (filename as NSString).pathExtension
        let type = UTType(filenameExtension: ext) ?? .data
        provider.suggestedName = filename

        provider.registerFileRepresentation(
            forTypeIdentifier: type.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            let progress = Progress(totalUnitCount: 1)
            Task {
                do {
                    // Unique temp dir so the original keeps its real filename.
                    let dir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("drag-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let dest = dir.appendingPathComponent(filename)
                    try await service.downloadOriginal(itemIds: [item.id], to: dest)
                    progress.completedUnitCount = 1
                    completion(dest, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return progress
        }
        return provider
    }
}
