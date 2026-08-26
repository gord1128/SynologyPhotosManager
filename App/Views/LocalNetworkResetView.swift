import SwiftUI
import AppKit

/// Shown instead of the generic "연결 실패" pane when the failure looks like
/// macOS's Local Network permission having come loose after an app update.
///
/// **Why this screen exists.** A sandboxed app needs Local Network permission to
/// reach a NAS by LAN address, and that permission is tied to the app's code
/// signature. Replacing the app — any update — changes the cdhash, and the
/// existing grant stops applying even though the switch in System Settings still
/// reads ON. The connection then fails as `-1009 "인터넷 연결이 오프라인
/// 상태입니다"`, which is a lie: the network is fine.
///
/// Diagnosed the slow way once already (a whole session), and the fix — toggle
/// the app's switch OFF then ON — is not something a user will ever deduce from
/// "인터넷 연결이 오프라인". `tccutil` does nothing here: Local Network isn't a
/// TCC service. A reboot isn't needed either.
///
/// Without notarization the app can't stay code-signed to a stable Developer ID
/// identity, so this will happen on every update we ship. It gets its own
/// screen, its own wording, and a button that opens the exact settings pane.
struct LocalNetworkResetView: View {
    let onRetry: () async -> Void
    let onDismiss: () -> Void

    @State private var openedSettings = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "network.badge.shield.half.filled")
                .font(.system(size: 42))
                .foregroundStyle(.orange)

            VStack(spacing: 8) {
                Text("업데이트 후 네트워크 권한을 다시 켜야 합니다")
                    .font(.title2).bold()
                    .multilineTextAlignment(.center)
                Text("앱을 새로 설치하면 macOS가 이 앱을 새 앱으로 봅니다. 로컬 네트워크 허용이 켜져 있어도 실제로는 적용되지 않아, NAS에 닿지 못하고 “인터넷 연결이 오프라인”처럼 보입니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            VStack(alignment: .leading, spacing: 7) {
                step(1, "아래 버튼으로 **로컬 네트워크** 설정을 엽니다")
                step(2, "목록에서 **SynologyPhotosManager**를 껐다가 다시 켭니다")
                step(3, "여기로 돌아와 **다시 연결**을 누릅니다")
            }
            .padding(14)
            .frame(maxWidth: 420, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 10) {
                Button("로컬 네트워크 설정 열기") {
                    openSettings()
                    openedSettings = true
                }
                .buttonStyle(.borderedProminent)

                Button("다시 연결") { Task { await onRetry() } }
                Button("닫기") { onDismiss() }
            }

            Text("재부팅은 필요 없습니다. 목록에 같은 이름이 두 줄 보이는 것은 정상이며 그대로 두어도 됩니다.")
                .font(.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("\(n)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(.orange, in: Circle())
            Text(.init(text)).font(.callout)
        }
    }

    /// Deep-links straight to the Local Network pane. The anchor moves between
    /// macOS releases, so a failed open falls back to the Privacy & Security
    /// root rather than leaving the user with a dead button.
    private func openSettings() {
        let deep = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork")
        let fallback = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")
        if let deep, NSWorkspace.shared.open(deep) { return }
        if let fallback { NSWorkspace.shared.open(fallback) }
    }
}
