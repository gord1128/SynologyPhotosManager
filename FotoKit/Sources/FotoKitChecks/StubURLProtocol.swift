import Foundation

/// Serves canned responses so FotoService can be checked offline. Records the
/// last request URL so tests can assert space routing (SYNO.Foto vs FotoTeam).
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var _handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) private(set) static var lastRequestURL: URL?
    private static let lock = NSLock()

    static func setHandler(_ handler: ((URLRequest) -> (Int, Data))?) {
        lock.lock(); defer { lock.unlock() }
        _handler = handler; lastRequestURL = nil
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
        Self.lock.lock(); Self.lastRequestURL = request.url; Self.lock.unlock()
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
