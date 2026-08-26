import Foundation

/// Serves canned responses so FotoService can be checked offline. Records the
/// last request URL so tests can assert space routing (SYNO.Foto vs FotoTeam).
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var _handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) private(set) static var lastRequestURL: URL?
    /// Body of the last request. A file-streamed upload arrives as
    /// `httpBodyStream`, never `httpBody`, so both are captured — it's the only
    /// way to check the multipart envelope without a real NAS.
    nonisolated(unsafe) private(set) static var lastRequestBody: Data?
    nonisolated(unsafe) private(set) static var lastContentType: String?
    private static let lock = NSLock()

    static func setHandler(_ handler: ((URLRequest) -> (Int, Data))?) {
        lock.lock(); defer { lock.unlock() }
        _handler = handler; lastRequestURL = nil; lastRequestBody = nil; lastContentType = nil
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            collected.append(buffer, count: read)
        }
        return collected
    }

    private static func handler() -> ((URLRequest) -> (Int, Data))? {
        lock.lock(); defer { lock.unlock() }
        return _handler
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let capturedBody = Self.body(of: request)
        let capturedType = request.value(forHTTPHeaderField: "Content-Type")
        Self.lock.lock()
        Self.lastRequestURL = request.url
        Self.lastRequestBody = capturedBody
        Self.lastContentType = capturedType
        Self.lock.unlock()
        guard let handler = Self.handler() else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown)); return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
