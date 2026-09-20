import Foundation

// Compile with a review copy of StockSageBenzinga.swift whose ephemeral session
// has configuration.protocolClasses = [ReviewProtocol.self]. No real network or Keychain.
enum ToolPolicy { nonisolated static var isExternalAllowed: Bool { true } }

final class ReviewProtocol: URLProtocol, @unchecked Sendable {
    static let counters = Counters()
    final class Counters: @unchecked Sendable {
        private let lock = NSLock()
        private var delivered = 0
        private var stopped = false
        func reset() { lock.withLock { delivered = 0; stopped = false } }
        func add(_ size: Int) -> Bool {
            lock.withLock {
                guard !stopped else { return false }
                delivered += size
                return true
            }
        }
        func stop() { lock.withLock { stopped = true } }
        var bytes: Int { lock.withLock { delivered } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        DispatchQueue.global().async { [self] in
            let chunk = Data(repeating: 32, count: 65_536)
            for _ in 0..<128 {
                guard Self.counters.add(chunk.count) else { return }
                client?.urlProtocol(self, didLoad: chunk)
                Thread.sleep(forTimeInterval: 0.001)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { Self.counters.stop() }
}

@main struct StreamReview {
    static func main() async {
        ReviewProtocol.counters.reset()
        let request = URLRequest(url: URL(string: "https://review.invalid/synthetic")!)
        let result = await StockSageBenzinga.fetch(request)
        let delivered = ReviewProtocol.counters.bytes
        precondition(result == .tooLarge, "Expected the production reader to reject the large body")
        print("reader_result=tooLarge limit=\(StockSageBenzinga.responseLimit) delivered_bytes=\(delivered)")
        // One chunk of overshoot is transport granularity; larger excess reveals read-ahead.
        if delivered > StockSageBenzinga.responseLimit + 65_536 {
            print("CONFIRMED: AsyncBytes allowed more than one extra chunk into URLSession before cancellation")
            exit(1)
        } else {
            print("PASS: transport stayed within one chunk of the reader limit")
        }
    }
}
