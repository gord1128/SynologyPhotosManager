import SwiftUI
import SynoKit
import FotoKit

/// The ⌘, settings window (plan D4): manage NAS connections, default timeline
/// unit, and the thumbnail disk cache. Styled after macOS System Settings —
/// grouped cards with colored SF Symbol icon badges per row.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("일반", systemImage: "gearshape") }
            ConnectionSettings()
                .tabItem { Label("연결", systemImage: "externaldrive.connected.to.line.below") }
        }
        .frame(width: 480, height: 400)
    }
}

/// A colored rounded-square SF Symbol badge — the System-Settings row-icon look.
struct SettingsIcon: View {
    let symbol: String
    let tint: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// A row label with a leading colored icon badge.
private func rowLabel(_ title: String, _ symbol: String, _ tint: Color) -> some View {
    Label { Text(title) } icon: { SettingsIcon(symbol: symbol, tint: tint) }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var cacheSize: Int?
    @State private var clearing = false
    @State private var user: FotoUserInfo?
    @State private var index: FotoIndexStatus?

    var body: some View {
        Form {
            if let user {
                Section("계정") {
                    LabeledContent {
                        HStack(spacing: 6) {
                            Text(user.name)
                            if user.isAdmin {
                                Text("관리자").font(.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.blue.opacity(0.2), in: Capsule())
                            }
                        }
                    } label: { rowLabel("사용자", "person.fill", .blue) }

                    if let email = user.profile?.email, !email.isEmpty {
                        LabeledContent { Text(email).foregroundStyle(.secondary) }
                            label: { rowLabel("이메일", "envelope.fill", .teal) }
                    }
                    if let index {
                        LabeledContent {
                            Text(index.isComplete ? "완료" : "\(index.remaining)개 처리 중")
                                .foregroundStyle(.secondary)
                        } label: {
                            rowLabel("색인 상태",
                                     index.isComplete ? "checkmark.seal.fill" : "arrow.triangle.2.circlepath",
                                     index.isComplete ? .green : .orange)
                        }
                    }
                }
            }

            Section {
                Picker(selection: Binding(get: { model.defaultScale }, set: { model.defaultScale = $0 })) {
                    ForEach(TimelineScale.allCases) { Text($0.rawValue).tag($0) }
                } label: { rowLabel("타임라인 단위", "calendar", .indigo) }
                .pickerStyle(.menu)
            } header: {
                Text("기본 보기")
            } footer: {
                Text("새 연결을 열 때 처음 보여줄 타임라인 묶음 단위입니다.")
            }

            Section {
                LabeledContent {
                    Text(cacheSizeLabel).foregroundStyle(.secondary).monospacedDigit()
                } label: { rowLabel("디스크 사용량", "internaldrive.fill", .gray) }

                Button {
                    clearing = true
                    Task {
                        await DiskImageCache.shared.clear()
                        cacheSize = await DiskImageCache.shared.currentSize()
                        clearing = false
                    }
                } label: {
                    rowLabel(clearing ? "비우는 중…" : "캐시 비우기", "trash.fill", .red)
                }
                .disabled(clearing)
            } header: {
                Text("썸네일 캐시")
            } footer: {
                Text("원본은 NAS에 그대로 있습니다. 썸네일은 다시 필요할 때 자동으로 내려받습니다.")
            }
        }
        .formStyle(.grouped)
        .task {
            cacheSize = await DiskImageCache.shared.currentSize()
            user = try? await model.fotoService?.userInfo()
            index = try? await model.fotoService?.indexStatus()
        }
    }

    private var cacheSizeLabel: String {
        guard let cacheSize else { return "계산 중…" }
        return ByteCountFormatter.string(fromByteCount: Int64(cacheSize), countStyle: .file)
    }
}

private struct ConnectionSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                if model.connections.isEmpty {
                    ContentUnavailableView("등록된 연결 없음", systemImage: "externaldrive.badge.questionmark")
                } else {
                    ForEach(model.connections) { connection in
                        LabeledContent {
                            HStack(spacing: 8) {
                                if isActive(connection) {
                                    Text(model.connectionState == .connected ? "연결됨" : "현재")
                                        .font(.caption)
                                        .foregroundStyle(model.connectionState == .connected ? .green : .secondary)
                                } else {
                                    Button("전환") { Task { await model.switchConnection(to: connection) } }
                                        .controlSize(.small)
                                }
                                Button(role: .destructive) {
                                    Task { await model.removeConnection(connection) }
                                } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("이 연결 삭제")
                            }
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(connection.nickname ?? connection.host)
                                    Text("\(connection.username)@\(connection.host):\(connection.port)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                SettingsIcon(symbol: "externaldrive.fill",
                                             tint: isActive(connection) ? .accentColor : .gray)
                            }
                        }
                    }
                }
            } header: {
                Text("등록된 NAS")
            }

            if model.connectionState == .connected {
                Section {
                    Button(role: .destructive) { model.disconnect() } label: {
                        rowLabel("로그아웃", "rectangle.portrait.and.arrow.right", .red)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func isActive(_ connection: NASConnection) -> Bool {
        connection.id == model.selectedConnection?.id
    }
}
