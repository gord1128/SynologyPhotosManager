import SwiftUI
import AppKit
import FotoKit

/// A single square thumbnail in the grid. Loads its image lazily via the shared
/// loader and cancels naturally when scrolled offscreen (SwiftUI `.task`).
struct ThumbnailCell: View {
    let item: FotoItem
    let loader: ThumbnailLoader
    let isSelected: Bool
    /// When true the cell fills whatever frame the parent gives it (justified
    /// timeline); when false it forces a 1:1 square (adaptive detail grids).
    var fillsFrame = false

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        RoundedRectangle(cornerRadius: DS.rThumb, style: .continuous)
            .fill(.quaternary)
            .modifier(SquareIfNeeded(square: !fillsFrame))
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else if failed {
                    // Load failed — show a placeholder instead of spinning forever.
                    Image(systemName: "photo")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.type == .video {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").font(.system(size: 8))
                        if let label = item.videoDurationLabel {
                            Text(label).font(.caption2).monospacedDigit()
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule())
                    .shadow(radius: 1)
                    .padding(4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.rThumb, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: DS.rThumb, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.rThumb, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2.5 : 0)
        }
        .task(id: item.id) {
            failed = false
            image = await loader.image(for: item, size: .m)
            if image == nil { failed = true }
        }
    }
}

/// Forces a 1:1 aspect ratio only for the adaptive detail grids; the justified
/// timeline lets the parent size the cell (so photos keep their real shape).
private struct SquareIfNeeded: ViewModifier {
    let square: Bool
    func body(content: Content) -> some View {
        if square { content.aspectRatio(1, contentMode: .fit) }
        else { content }
    }
}
