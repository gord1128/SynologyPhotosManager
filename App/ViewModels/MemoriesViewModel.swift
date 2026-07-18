import Foundation
import Observation
import FotoKit

/// Drives "추억 (이 날의 추억 / On this day)" — photos taken on today's month-day
/// in previous years (Google Photos Memories / Apple Photos "추억"). Purely
/// DERIVED from taken-time: no server feature, no new API. Each past year is a
/// separate single-range `filteredItems` query (the single-range time filter is
/// verified), run concurrently and grouped by year.
@Observable
@MainActor
final class MemoriesViewModel {
    let service: FotoService
    let thumbnailLoader: ThumbnailLoader

    struct YearGroup: Identifiable {
        let year: Int
        let yearsAgo: Int
        let items: [FotoItem]
        var id: Int { year }
        /// "작년 오늘" / "N년 전 오늘".
        var title: String { yearsAgo == 1 ? "작년 오늘" : "\(yearsAgo)년 전 오늘" }
    }

    private(set) var groups: [YearGroup] = []
    private(set) var isLoading = false
    private(set) var didLoad = false
    var errorMessage: String?

    /// The month-day these memories are for (for the header).
    let todayLabel: String

    /// How many years back to look. Bounded — most libraries span < 15 years.
    private let yearsBack = 15

    init(service: FotoService) {
        self.service = service
        self.thumbnailLoader = ThumbnailLoader(service: service)
        self.todayLabel = Date().formatted(.dateTime.month(.wide).day())
    }

    func loadIfNeeded() async {
        guard !didLoad else { return }
        await reload()
    }

    func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false; didLoad = true }

        let cal = Calendar.current
        let today = cal.dateComponents([.year, .month, .day], from: Date())
        guard let thisYear = today.year, let month = today.month, let day = today.day else { return }

        // Precompute each past year's [startOfDay, endOfDay] window on the main
        // actor, then query them concurrently (each a verified single-range call).
        let windows: [(year: Int, yearsAgo: Int, range: (start: Int, end: Int))] =
            (1...yearsBack).compactMap { offset in
                guard let range = Self.dayRange(year: thisYear - offset, month: month, day: day, cal: cal)
                else { return nil }
                return (thisYear - offset, offset, range)
            }

        var collected: [(year: Int, yearsAgo: Int, items: [FotoItem])] = []
        await withTaskGroup(of: (Int, Int, [FotoItem]).self) { group in
            for w in windows {
                group.addTask { [service] in
                    let items = (try? await service.filteredItems(
                        itemTypes: [0, 1], timeRanges: [w.range], offset: 0, limit: 300)) ?? []
                    return (w.year, w.yearsAgo, items)
                }
            }
            for await result in group where !result.2.isEmpty {
                collected.append(result)
            }
        }

        groups = collected
            .sorted { $0.year > $1.year }   // most recent year first
            .map { YearGroup(year: $0.year, yearsAgo: $0.yearsAgo, items: $0.items) }
    }

    /// The unix-second [startOfDay, endOfDay] window for a specific calendar day.
    private static func dayRange(year: Int, month: Int, day: Int, cal: Calendar) -> (start: Int, end: Int)? {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        guard let date = cal.date(from: comps) else { return nil }
        let start = cal.startOfDay(for: date)
        guard let end = cal.date(byAdding: DateComponents(day: 1, second: -1), to: start) else { return nil }
        return (Int(start.timeIntervalSince1970), Int(end.timeIntervalSince1970))
    }
}
