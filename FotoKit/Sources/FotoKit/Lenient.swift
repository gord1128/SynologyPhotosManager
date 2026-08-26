import Foundation
import SynoKit

/// Wraps one array element so its decoding failure becomes `nil` instead of
/// throwing. The wrapper itself never throws, which is the whole point: the
/// unkeyed container's index always advances. (Repeating
/// `try? container.decode(T.self)` on a raw unkeyed container does NOT advance
/// past a failed element — that spins forever.)
struct Failable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// Decodes an array element-wise, dropping the elements that don't fit our
    /// schema instead of failing the whole list.
    ///
    /// Why this exists: DSM's field set varies by firmware version, by item
    /// kind, and between the personal (`SYNO.Foto.*`) and shared
    /// (`SYNO.FotoTeam.*`) spaces. With a strict `[FotoItem]` decode, ONE
    /// unexpected row anywhere in a 400-item page throws — the user sees an
    /// empty grid and "응답을 해석할 수 없습니다" for a library that is 99.8%
    /// fine, and every retry hits the same offset, so the timeline is stuck
    /// there for good.
    ///
    /// Dropped rows are logged (SynoKit's shared `decoding` category), never swallowed silently: a non-zero count is
    /// how we find out the NAS is sending a shape we don't know about.
    func decodeLenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
        let raw = (try? decodeIfPresent([Failable<T>].self, forKey: key)) ?? []
        let values = raw.compactMap(\.value)
        let dropped = raw.count - values.count
        if dropped > 0 {
            SynoLog.decoding.warning(
                "\(String(describing: T.self), privacy: .public): \(dropped, privacy: .public)/\(raw.count, privacy: .public)개가 스키마 불일치로 버려짐")
        }
        return values
    }
}
