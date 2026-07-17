import Foundation
import CoreGraphics
import FotoKit

/// Packs photos into justified rows (Google Photos / Flickr / Apple "Aspect
/// Ratio Grid" style): each row keeps every photo's aspect ratio and is scaled
/// to fill the container width at roughly `targetHeight`. No cropping.
enum JustifiedLayout {
    /// One photo laid out at a concrete size within its row.
    struct Tile: Identifiable {
        let item: FotoItem
        let width: CGFloat
        let height: CGFloat
        var id: Int { item.id }
    }

    /// A row of tiles (already sized to fill the width).
    struct Row: Identifiable {
        let id: Int          // first item's id — stable for ForEach
        let tiles: [Tile]
    }

    /// Aspect ratios are clamped so a panorama or a tall strip can't blow up a row.
    private static let minAspect: CGFloat = 0.45
    private static let maxAspect: CGFloat = 3.0

    static func rows(_ items: [FotoItem], width: CGFloat, targetHeight: CGFloat, gap: CGFloat) -> [Row] {
        guard width > 0, targetHeight > 0, !items.isEmpty else { return [] }

        var rows: [Row] = []
        var line: [(item: FotoItem, aspect: CGFloat)] = []
        var lineWidth: CGFloat = 0     // width of the line at targetHeight

        func aspect(_ item: FotoItem) -> CGFloat {
            min(max(CGFloat(item.aspectRatio), minAspect), maxAspect)
        }

        func commit(fill: Bool) {
            guard let first = line.first else { return }
            let totalGap = gap * CGFloat(line.count - 1)
            let sumAspect = line.reduce(0) { $0 + $1.aspect }
            // Fill rows stretch to the width; the trailing partial row keeps
            // `targetHeight` (left-aligned), like Google Photos.
            let rowHeight = fill ? (width - totalGap) / sumAspect : targetHeight
            let tiles = line.map { Tile(item: $0.item, width: (rowHeight * $0.aspect).rounded(), height: rowHeight.rounded()) }
            rows.append(Row(id: first.item.id, tiles: tiles))
            line = []
            lineWidth = 0
        }

        for item in items {
            let a = aspect(item)
            let w = targetHeight * a
            let projected = lineWidth + (line.isEmpty ? 0 : gap) + w
            if !line.isEmpty && projected > width {
                commit(fill: true)
            }
            line.append((item, a))
            lineWidth += (line.count == 1 ? 0 : gap) + targetHeight * a
        }
        commit(fill: false)
        return rows
    }
}
