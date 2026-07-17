import SwiftUI
import FotoKit

/// Share sheet for an album: create a public link, copy/open it, or disable it.
/// NOTE: currently NOT wired into the UI (sharing removed for solo use) — kept
/// with `ShareViewModel` + `FotoService.createShareLink/setSharePublic/shareInfo`
/// so it can be re-enabled by re-adding a 공유 button + `.sheet(ShareSheet(…))`.
struct ShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ShareViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("공유", systemImage: "square.and.arrow.up").font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }

            Text(model.album.name).font(.title3).lineLimit(1)
            Text("\(model.album.itemCount)장").font(.caption).foregroundStyle(.secondary)

            Divider()

            if model.isShared {
                sharedView
            } else {
                unsharedView
            }

            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private var unsharedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("이 앨범의 사진을 링크가 있는 누구나 볼 수 있게 공유합니다.")
                .font(.callout).foregroundStyle(.secondary)
            Button {
                Task { await model.createLink() }
            } label: {
                Label(model.isWorking ? "만드는 중…" : "공유 링크 만들기", systemImage: "link.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isWorking)
        }
    }

    private var sharedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("링크로 공유 중", systemImage: "checkmark.circle.fill")
                .font(.subheadline).foregroundStyle(.green)

            if let url = model.linkURL {
                HStack(spacing: 8) {
                    Text(url.absoluteString)
                        .font(.callout).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    Button { model.copyLink() } label: { Image(systemName: "doc.on.doc") }
                        .help("링크 복사")
                    Link(destination: url) { Image(systemName: "safari") }
                        .help("브라우저에서 열기")
                }
            }

            Button(role: .destructive) {
                Task { await model.disableLink() }
            } label: {
                Label(model.isWorking ? "해제 중…" : "공유 해제", systemImage: "link.badge.minus")
            }
            .disabled(model.isWorking)
        }
    }
}
