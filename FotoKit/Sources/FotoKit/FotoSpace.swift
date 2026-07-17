import Foundation

/// Which Synology Photos library space to browse. Personal maps to the
/// `SYNO.Foto.*` API namespace, shared to `SYNO.FotoTeam.*`.
public enum FotoSpace: String, CaseIterable, Identifiable, Sendable {
    case personal
    case shared
    public var id: String { rawValue }
}
