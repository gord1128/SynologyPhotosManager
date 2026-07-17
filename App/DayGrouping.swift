import Foundation
import FotoKit

/// Timeline grouping granularity (matches the Synology Photos 연도/월/일 switch).
enum TimelineScale: String, CaseIterable, Identifiable {
    case year = "연도"
    case month = "월"
    case day = "일"
    var id: String { rawValue }

    /// Thumbnail cell minimum width — coarser scale packs more, smaller cells.
    var cellMin: CGFloat {
        switch self {
        case .year: return 78
        case .month: return 108
        case .day: return 150
        }
    }
}

/// One timeline section (a year, month, or day worth of photos).
struct TimelineSection: Identifiable {
    let id: Int          // yyyy / yyyymm / yyyymmdd depending on scale
    let title: String
    let items: [FotoItem]
}

/// Groups items (already sorted newest-first) into sections at the given scale.
enum TimelineGrouping {
    static func key(for date: Date, scale: TimelineScale) -> Int {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let y = c.year ?? 0, m = c.month ?? 0, d = c.day ?? 0
        switch scale {
        case .year: return y
        case .month: return y * 100 + m
        case .day: return y * 10_000 + m * 100 + d
        }
    }

    static func title(for date: Date, scale: TimelineScale) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let y = c.year ?? 0, m = c.month ?? 0, d = c.day ?? 0
        switch scale {
        case .year: return "\(y)년"
        case .month: return "\(y)년 \(m)월"
        case .day: return "\(y)년 \(m)월 \(d)일"
        }
    }

    static func sections(from items: [FotoItem], scale: TimelineScale) -> [TimelineSection] {
        let groups = Dictionary(grouping: items) { key(for: $0.takenAt, scale: scale) }
        return groups.keys.sorted(by: >).compactMap { key in
            guard let sectionItems = groups[key], let first = sectionItems.first else { return nil }
            return TimelineSection(id: key, title: title(for: first.takenAt, scale: scale), items: sectionItems)
        }
    }
}
