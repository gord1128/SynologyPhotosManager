import Foundation
import AVFoundation
import UniformTypeIdentifiers
import FotoKit

/// Progressive video streaming for AVFoundation over the NAS's pinned self-signed
/// connection. AVPlayer can't stream directly from the NAS — it uses its own
/// networking and would reject the self-signed cert. So we hand AVURLAsset a URL
/// with a **custom scheme**, which makes AVFoundation delegate *all* loading here,
/// and we satisfy each byte-range request via `FotoService`'s trusted session
/// (the `SYNO.Foto.Download` endpoint supports HTTP Range — verified). Playback
/// starts immediately and seeking works, without downloading the whole file.
final class VideoStreamLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let scheme = "synostream"

    private let realURL: URL
    private let fetch: (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let queue = DispatchQueue(label: "com.synologyphotos.videostream")
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// Fetched once from the first range response.
    private var totalLength: Int64?
    private var contentUTI: String?

    private init(realURL: URL, fetch: @escaping (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.realURL = realURL
        self.fetch = fetch
    }

    /// Builds an AVURLAsset wired to stream via `service`. The returned loader
    /// MUST be retained by the caller for the lifetime of the asset — the
    /// resource loader holds its delegate weakly.
    static func makeAsset(itemId: Int, service: FotoService) -> (asset: AVURLAsset, loader: VideoStreamLoader)? {
        guard let realURL = service.videoStreamURL(itemId: itemId),
              var comps = URLComponents(url: realURL, resolvingAgainstBaseURL: false) else { return nil }
        comps.scheme = scheme  // force delegation to us
        guard let customURL = comps.url else { return nil }

        let loader = VideoStreamLoader(realURL: realURL) { [service] request in
            try await service.rawData(for: request)
        }
        let asset = AVURLAsset(url: customURL)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        return (asset, loader)
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let id = ObjectIdentifier(loadingRequest)
        tasks[id] = Task { [weak self] in
            await self?.handle(loadingRequest)
            self?.queue.async { self?.tasks[id] = nil }
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let id = ObjectIdentifier(loadingRequest)
        tasks[id]?.cancel()
        tasks[id] = nil
    }

    // MARK: - Handling

    private func handle(_ request: AVAssetResourceLoadingRequest) async {
        // Content information: learn total length + type from one tiny range.
        if let info = request.contentInformationRequest {
            do {
                if totalLength == nil { try await fetchContentInfo() }
                if let total = totalLength { info.contentLength = total }
                if let uti = contentUTI { info.contentType = uti }
                info.isByteRangeAccessSupported = true
            } catch {
                finish(request, with: error); return
            }
        }

        // Data: stream the requested byte range in bounded chunks.
        if let dataRequest = request.dataRequest {
            do {
                try await streamData(for: dataRequest, request: request)
            } catch {
                finish(request, with: error); return
            }
        }

        if !request.isFinished { request.finishLoading() }
    }

    private func fetchContentInfo() async throws {
        var req = URLRequest(url: realURL)
        req.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        let (_, http) = try await fetch(req)
        if let total = Self.totalLength(from: http) { totalLength = total }
        if let mime = http.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";").first.map({ String($0).trimmingCharacters(in: .whitespaces) }),
           let uti = UTType(mimeType: mime)?.identifier {
            contentUTI = uti
        }
    }

    private func streamData(for dataRequest: AVAssetResourceLoadingDataRequest,
                            request: AVAssetResourceLoadingRequest) async throws {
        let end: Int64 = dataRequest.requestsAllDataToEndOfResource
            ? (totalLength.map { $0 - 1 } ?? Int64.max)
            : dataRequest.requestedOffset + Int64(dataRequest.requestedLength) - 1
        let chunk: Int64 = 512 * 1024
        var offset = dataRequest.currentOffset

        while offset <= end {
            if Task.isCancelled { return }
            let upper = min(offset + chunk - 1, end)
            var req = URLRequest(url: realURL)
            req.setValue("bytes=\(offset)-\(upper == Int64.max ? "" : String(upper))", forHTTPHeaderField: "Range")
            let (data, http) = try await fetch(req)
            if data.isEmpty { break }
            dataRequest.respond(with: data)
            offset += Int64(data.count)
            if let total = Self.totalLength(from: http) ?? totalLength {
                totalLength = total
                if offset >= total { break }
            }
            if http.statusCode == 200 { break }  // server ignored range → whole file sent
        }
    }

    /// Parses the total resource length from a `Content-Range: bytes a-b/TOTAL`.
    private static func totalLength(from http: HTTPURLResponse) -> Int64? {
        guard let cr = http.value(forHTTPHeaderField: "Content-Range"),
              let totalPart = cr.split(separator: "/").last, let total = Int64(totalPart) else { return nil }
        return total
    }

    private func finish(_ request: AVAssetResourceLoadingRequest, with error: Error) {
        if Task.isCancelled { return }
        if !request.isFinished { request.finishLoading(with: error) }
    }
}
