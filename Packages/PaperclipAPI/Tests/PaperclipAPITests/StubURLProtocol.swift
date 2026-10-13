import Foundation

/// Serves canned responses so tests never reach a real server.
final class StubURLProtocol: URLProtocol {
    struct Stub {
        var status: Int = 200
        var body: Data = Data("{}".utf8)
    }

    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> Stub)?
    private(set) static var requests: [URLRequest] = []

    static func respond(_ handler: @escaping (URLRequest) -> Stub) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        requests = []
    }

    static var lastRequest: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return requests.last
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        // URLSession moves the body into a stream; keep it readable for assertions.
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            recorded.httpBody = Self.read(stream)
        }
        Self.lock.lock()
        Self.requests.append(recorded)
        let stub = Self.handler?(recorded) ?? Stub(status: 500)
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

struct MissingFixture: Error {
    let name: String
}

func fixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
        throw MissingFixture(name: name)
    }
    return try Data(contentsOf: url)
}
