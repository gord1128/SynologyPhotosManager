import SwiftUI

/// Trust-on-first-use prompt shown when the NAS presents an untrusted (usually
/// self-signed) certificate, or one that changed since it was last trusted.
struct CertificateTrustView: View {
    @Environment(AppModel.self) private var model
    let challenge: CertificateChallenge

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: challenge.isChange ? "exclamationmark.shield.fill" : "lock.shield")
                .font(.system(size: 40))
                .foregroundStyle(challenge.isChange ? .orange : .accentColor)

            Text(challenge.isChange ? "인증서가 변경되었습니다" : "새 인증서 확인")
                .font(.title2).bold()

            Text("\(challenge.host):\(challenge.port)")
                .font(.callout).foregroundStyle(.secondary)

            if challenge.isChange {
                Text("이 NAS의 인증서가 이전에 신뢰했던 것과 다릅니다. 네트워크가 가로채였을 수 있으니, 직접 변경한 것이 아니라면 신뢰하지 마세요.")
                    .font(.callout).foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            } else {
                Text("이 인증서를 신뢰하면 이 기기에 저장되어, 다음부터는 묻지 않습니다.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            fingerprintBox("현재 지문 (SHA-256)", challenge.fingerprint)
            if let previous = challenge.previousFingerprint {
                fingerprintBox("이전 지문", previous)
            }

            HStack {
                Button("취소") { model.rejectPendingCertificate() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(challenge.isChange ? "변경된 인증서 신뢰" : "신뢰하고 연결") {
                    Task { await model.trustPendingCertificate() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(challenge.isChange ? .orange : .accentColor)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func fingerprintBox(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
