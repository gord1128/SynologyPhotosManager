import OSLog

/// FotoKit's loggers. Categories match the layer a message comes from so
/// `log show --predicate 'subsystem == "com.hyeonm9.SynologyPhotosManager"'`
/// (and the app's 진단 로그 내보내기) can be filtered usefully.
///
/// Anything that identifies the user's NAS or library — host, username,
/// filenames — must be interpolated as `privacy: .private`. Counts, error
/// codes and type names are `.public` so a user-submitted log is actually
/// readable.
public enum FotoLog {
    private static let subsystem = "com.hyeonm9.SynologyPhotosManager"
    public static let decoding = Logger(subsystem: subsystem, category: "decoding")
    public static let service  = Logger(subsystem: subsystem, category: "foto-service")
}
