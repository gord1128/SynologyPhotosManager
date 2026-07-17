import SwiftUI
import SynoKit

/// Sheet to add a NAS connection and log in. On success the credential is saved
/// to this app's own store and the model connects.
struct AddConnectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var port = "5001"
    @State private var username = ""
    @State private var password = ""
    @State private var otpCode = ""
    @State private var needsOTP = false
    @State private var submitting = false
    @State private var error: String?

    // Auto-detect NAS on the local network.
    @State private var discovered: [DiscoveredNAS] = []
    @State private var scanning = false
    @State private var scanChecked = 0
    @State private var scanTotal = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Synology NAS 연결").font(.title2).bold()

            discoverySection

            Form {
                TextField("주소", text: $host, prompt: Text("192.168.0.10 또는 nas.example.com"))
                TextField("포트", text: $port)
                TextField("사용자 이름", text: $username)
                SecureField("비밀번호", text: $password)
                if needsOTP {
                    TextField("2단계 인증 코드", text: $otpCode)
                }
            }
            .formStyle(.grouped)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button(submitting ? "연결 중…" : "연결") { Task { await submit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(submitting || host.isEmpty || username.isEmpty || password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: - Auto-detect

    @ViewBuilder
    private var discoverySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    Task { await scan() }
                } label: {
                    Label(scanning ? "찾는 중…" : "네트워크에서 찾기", systemImage: "wifi")
                }
                .disabled(scanning)
                if scanning {
                    ProgressView(value: scanTotal > 0 ? Double(scanChecked) / Double(scanTotal) : 0)
                        .frame(width: 90)
                    Text("\(scanChecked)/\(scanTotal)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if !discovered.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(discovered) { nas in
                        Button {
                            host = nas.host
                            port = String(nas.port)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "externaldrive.fill").foregroundStyle(.tint)
                                Text("\(nas.host):\(nas.port)")
                                Spacer()
                                if host == nas.host { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                            .padding(.vertical, 4).padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .background(host == nas.host ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if !scanning {
                Text("같은 네트워크의 Synology NAS를 자동으로 찾습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func scan() async {
        guard !scanning else { return }
        scanning = true
        discovered = []
        scanChecked = 0; scanTotal = 0
        defer { scanning = false }
        await NASDiscoveryService.scan(
            onDiscovered: { nas in
                if !discovered.contains(nas) { discovered.append(nas) }
                // Prefill the first find for convenience.
                if host.isEmpty { host = nas.host; port = String(nas.port) }
            },
            onProgress: { progress in
                scanChecked = progress.checked
                scanTotal = progress.total
            }
        )
    }

    private func submit() async {
        submitting = true
        error = nil
        defer { submitting = false }

        let portNumber = Int(port) ?? 5001
        await model.addConnection(
            host: host.trimmingCharacters(in: .whitespaces),
            port: portNumber,
            username: username.trimmingCharacters(in: .whitespaces),
            password: password,
            otpCode: needsOTP ? otpCode : nil
        )

        // A cert-trust prompt means we must close this sheet so the trust sheet
        // can show; the connection resumes after the user decides.
        if model.pendingCertificate != nil {
            dismiss()
            return
        }

        switch model.connectionState {
        case .connected:
            dismiss()
        case .failed(let message):
            if message.contains("2단계") { needsOTP = true }
            error = message
        default:
            break
        }
    }
}
