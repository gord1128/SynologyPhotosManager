import Foundation
import AppKit
import OSLog
import SynoKit

/// Everything needed to answer "무슨 일이 있었나?" from a machine that isn't mine.
///
/// The app ships ad-hoc-signed outside the App Store, so there is no crash
/// dashboard and no way to ask a user for a stack trace — the only channel is
/// what they can copy out of the app themselves. Two things make that workable:
/// a version line precise enough to identify the exact build, and an export of
/// this process's unified-log entries.
///
/// No third-party SDK, no network transmission, no consent dialog: the log
/// never leaves the machine unless the user saves it and sends it.
enum Diagnostics {

    // MARK: - Build identity

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// Build number. `Tools/release.sh` sets it from the commit count, so it
    /// rises on its own and maps back to a commit — a hand-maintained number
    /// would sit at "1" forever (it did, in a sibling project).
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    /// Short commit hash of the tree this build came from, stamped into the
    /// bundle by `Tools/release.sh`. Absent in local Xcode builds.
    static var commit: String? {
        Bundle.main.object(forInfoDictionaryKey: "SPMCommit") as? String
    }

    /// SynoKit is a sibling package, not vendored, so a build is only fully
    /// identified by both hashes.
    static var synoKitCommit: String? {
        Bundle.main.object(forInfoDictionaryKey: "SPMSynoKitCommit") as? String
    }

    /// "0.1.0 (137 · a1b2c3d)" — the one string a bug report can't do without.
    /// A hand-typed version number is wrong often enough to be useless; the
    /// commit makes it exact.
    static var versionLine: String {
        guard let commit else { return "\(version) (\(build))" }
        return "\(version) (\(build) · \(commit))"
    }

    static var systemLine: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(hardwareModel) · \(architecture)"
    }

    /// e.g. "Mac14,2". Distinguishes Apple silicon from Intel and, with the OS
    /// version, is usually enough to reproduce a "느려요" report.
    private static var hardwareModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "알 수 없음" }
        var chars = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &chars, &size, nil, 0)
        return String(cString: chars)
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    // MARK: - Log export

    enum ExportError: LocalizedError {
        case storeUnavailable(Error)

        var errorDescription: String? {
            switch self {
            case .storeUnavailable: return "시스템 로그를 읽을 수 없습니다."
            }
        }
    }

    /// Collects this process's own log entries from the last `hours` hours.
    ///
    /// Scope is `.currentProcessIdentifier`: it needs no entitlement, works
    /// inside the sandbox, and — the point — can only ever read our own lines,
    /// never another app's. The subsystem filter drops the OS-level noise that
    /// gets attributed to us (SwiftUI, network stack).
    ///
    /// An empty result is NOT an error. Writes to the unified log are
    /// asynchronous — measured: entries emitted and read back immediately came
    /// out as zero rows, and the same read a couple of seconds later returned
    /// them — so a fresh launch (or an export fired right after the failure)
    /// can legitimately find nothing. The header alone still identifies the
    /// build, which is most of what a report needs.
    static func collectLog(hours: Int = 6) throws -> String {
        let store: OSLogStore
        do { store = try OSLogStore(scope: .currentProcessIdentifier) }
        catch { throw ExportError.storeUnavailable(error) }

        let since = store.position(date: Date().addingTimeInterval(-Double(hours) * 3600))
        let predicate = NSPredicate(format: "subsystem == %@", SynoLog.subsystem)
        let entries = try store.getEntries(at: since, matching: predicate)

        let stamp = DateFormatter()
        stamp.dateFormat = "HH:mm:ss.SSS"

        var lines: [String] = [
            "SynologyPhotosManager \(versionLine)",
            systemLine,
            "수집: 최근 \(hours)시간 · \(ISO8601DateFormatter().string(from: Date()))",
            String(repeating: "─", count: 60),
        ]
        var count = 0
        for case let entry as OSLogEntryLog in entries {
            lines.append("\(stamp.string(from: entry.date))  [\(entry.category)] \(levelMark(entry.level)) \(entry.composedMessage)")
            count += 1
        }
        if count == 0 {
            lines.append("(이 기간에 기록된 로그가 없습니다. 방금 일어난 일이라면 몇 초 뒤 다시 내보내 주세요.)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func levelMark(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .fault: return "‼️"
        case .error: return "✘"
        case .notice: return "·"
        default: return " "
        }
    }

    /// Saves the collected log wherever the user picks. Returns false if they
    /// cancelled; throws if there was nothing to collect.
    @MainActor
    @discardableResult
    static func exportLog() throws -> Bool {
        let text = try collectLog()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SynologyPhotosManager-log-\(Self.fileStamp).txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    private static var fileStamp: String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: Date())
    }

    // MARK: - Problem report

    /// Opens a new GitHub issue with the environment already filled in. Users
    /// will not type a version number correctly, and a report without one is
    /// usually unactionable — so we type it for them.
    @MainActor
    static func openIssueReport() {
        let body = """
        <!-- 무엇을 하려다 무슨 일이 났는지 적어 주세요. 재현 방법이 있으면 함께요. -->


        ---
        - 앱: \(versionLine)\(synoKitCommit.map { " · SynoKit \($0)" } ?? "")
        - 환경: \(systemLine)
        - 진단 로그: 설정 › 일반 › 「진단 로그 내보내기」로 저장한 파일을 첨부해 주시면 큰 도움이 됩니다.
        """
        var components = URLComponents(string: "https://github.com/gord1128/SynologyPhotosManager/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "labels", value: "bug"),
            URLQueryItem(name: "body", value: body),
        ]
        guard let url = components?.url else { return }
        NSWorkspace.shared.open(url)
    }
}
