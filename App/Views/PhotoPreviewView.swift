import SwiftUI
import AppKit
import AVKit
import FotoKit

/// Full-window Quick Look preview for the selected item. Photos show the large
/// `xl` thumbnail; videos play via AVKit's `VideoPlayer`, streamed progressively
/// through `VideoStreamLoader` (byte-range requests over the app's trusted,
/// cert-pinned session) — playback starts immediately without downloading the
/// whole file. Dismiss via backdrop, close button, or Escape.
struct PhotoPreviewView: View {
    @Environment(AppModel.self) private var model
    let item: FotoItem
    let loader: ThumbnailLoader
    let onClose: () -> Void
    let onPrev: () -> Void
    let onNext: () -> Void

    private enum VideoState: Equatable { case idle, loading, ready, failed }

    @State private var image: NSImage?
    /// Full-resolution original, loaded lazily the first time the user zooms in
    /// (photos only). Falls back to the `xl` thumbnail until then.
    @State private var originalImage: NSImage?
    @State private var isLoadingOriginal = false
    /// Auto-hiding chrome (title bar + nav arrows) like a real photo viewer.
    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var player: AVPlayer?
    @State private var videoState: VideoState = .idle
    /// Retains the resource-loader delegate for the player item's lifetime
    /// (AVAssetResourceLoader holds its delegate weakly).
    @State private var streamLoader: VideoStreamLoader?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.92))
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            content

            VStack {
                HStack {
                    Text(item.filename)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.black.opacity(0.4), in: Capsule())
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.8))
                }
                .padding(16)
                Spacer()
            }
            .opacity(chromeVisible ? 1 : 0)

            HStack {
                navButton("chevron.left", action: onPrev)
                Spacer()
                navButton("chevron.right", action: onNext)
            }
            .padding(.horizontal, 16)
            .opacity(chromeVisible ? 1 : 0)
        }
        .animation(.easeInOut(duration: 0.2), value: chromeVisible)
        // Reveal chrome on mouse movement; auto-hide when idle.
        .onContinuousHover { phase in
            if case .active = phase { pokeChrome() }
        }
        .task(id: item.id) { await load() }
        .onAppear { pokeChrome() }
        .onDisappear { teardownVideo(); hideTask?.cancel() }
    }

    /// Shows the chrome and schedules it to fade out after a short idle period.
    private func pokeChrome() {
        chromeVisible = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { chromeVisible = false }
        }
    }

    @ViewBuilder
    private var content: some View {
        if item.type == .video, videoState == .ready, let player {
            VideoPlayer(player: player)
                .padding(24)
        } else if let image {
            if item.type == .video {
                // Poster: the still frame, with a spinner/badge while a video loads.
                ZStack {
                    Image(nsImage: image).resizable().scaledToFit().padding(48)
                    videoPosterOverlay
                }
            } else {
                // Photo: zoomable/pannable, upgrading to the original on zoom-in.
                ZoomableImageView(
                    image: originalImage ?? image,
                    isOriginal: originalImage != nil,
                    onZoomIn: { Task { await loadOriginalIfNeeded() } }
                )
                .id(item.id)
            }
        } else {
            ProgressView().controlSize(.large).tint(.white)
        }
    }

    @ViewBuilder
    private var videoPosterOverlay: some View {
        switch videoState {
        case .loading:
            VStack(spacing: 10) {
                ProgressView().controlSize(.large).tint(.white)
                Text("영상 불러오는 중…").font(.callout).foregroundStyle(.white.opacity(0.85))
            }
            .padding(20)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        case .failed:
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                Text("영상을 재생할 수 없습니다").font(.callout).foregroundStyle(.white)
            }
            .padding(20)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        default:
            Image(systemName: "play.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.white.opacity(0.85))
                .shadow(radius: 6)
        }
    }

    private func load() async {
        // Reset for the new item and clean up any previous video.
        teardownVideo()
        image = nil
        originalImage = nil
        isLoadingOriginal = false
        image = await loader.image(for: item, size: .xl)
        if item.type == .video { await prepareVideo() }
    }

    /// Fetches the full-resolution original once (photos only) so zooming stays
    /// crisp. The `xl` thumbnail is shown until this arrives.
    private func loadOriginalIfNeeded() async {
        guard item.type == .photo, originalImage == nil, !isLoadingOriginal,
              let service = model.fotoService else { return }
        isLoadingOriginal = true
        defer { isLoadingOriginal = false }
        if let data = try? await service.originalData(itemIds: [item.id]),
           let full = NSImage(data: data) {
            originalImage = full
        }
    }

    private func prepareVideo() async {
        guard let service = model.fotoService,
              let (asset, loader) = VideoStreamLoader.makeAsset(itemId: item.id, service: service) else {
            videoState = .failed; return
        }
        videoState = .loading
        streamLoader = loader
        let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player = p
        videoState = .ready
        p.play()
    }

    private func teardownVideo() {
        player?.pause()
        player = nil
        streamLoader = nil
        videoState = .idle
    }

    private func navButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(.white.opacity(0.8))
                .padding(12)
                .background(.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// A zoomable/pannable image: pinch (trackpad) or double-click to zoom, drag to
/// pan while zoomed. Reports the first zoom-in so the host can upgrade the
/// thumbnail to the full-resolution original.
private struct ZoomableImageView: View {
    let image: NSImage
    let isOriginal: Bool
    let onZoomIn: () -> Void

    @State private var scale: CGFloat = 1
    @State private var steadyScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var steadyOffset: CGSize = .zero
    @State private var didRequestOriginal = false

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 6

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .gesture(magnify)
            .simultaneousGesture(pan)
            .onTapGesture(count: 2) { toggleZoom() }
            .overlay(alignment: .bottom) { zoomBadge }
            .padding(48)
            .contentShape(Rectangle())
            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.8), value: scale)
            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.8), value: offset)
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = clampedScale(steadyScale * value.magnification)
                requestOriginalIfZoomed()
            }
            .onEnded { _ in
                steadyScale = scale
                if scale <= minScale { resetPan() }
                steadyOffset = offset
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > minScale else { return }
                offset = CGSize(width: steadyOffset.width + value.translation.width,
                                height: steadyOffset.height + value.translation.height)
            }
            .onEnded { _ in steadyOffset = offset }
    }

    private func toggleZoom() {
        if scale > minScale {
            scale = minScale; steadyScale = minScale; resetPan()
        } else {
            scale = 2.5; steadyScale = 2.5; requestOriginalIfZoomed()
        }
    }

    private func requestOriginalIfZoomed() {
        guard scale > minScale, !didRequestOriginal else { return }
        didRequestOriginal = true
        onZoomIn()
    }

    private func resetPan() { offset = .zero; steadyOffset = .zero }
    private func clampedScale(_ s: CGFloat) -> CGFloat { min(max(s, minScale), maxScale) }

    @ViewBuilder
    private var zoomBadge: some View {
        if scale > minScale {
            Text(isOriginal ? String(format: "%.0f%% · 원본", scale * 100) : String(format: "%.0f%%", scale * 100))
                .font(.caption).monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(.bottom, 8)
        }
    }
}
