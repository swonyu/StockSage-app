import Foundation

/// Caps accumulated response Data and cancels on detected overflow. URLSession-owned
/// buffering and total wire traffic are outside this cap. Callers own host/policy checks.
enum StockSageHTTP {
    nonisolated final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    @concurrent nonisolated static func data(for request: URLRequest, session: URLSession,
                                           maximumBytes: Int) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        #if os(iOS)
        // Transport-level boundary as well as the caller's policy check. Injected
        // parsing/test transports remain usable without enabling actual requests.
        guard ToolPolicy.isExternalAllowed else { throw URLError(.notConnectedToInternet) }
        #endif
        guard maximumBytes >= 0 else { throw URLError(.dataLengthExceedsMaximum) }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard response.expectedContentLength <= Int64(maximumBytes) else { throw URLError(.dataLengthExceedsMaximum) }
        return try await withTaskCancellationHandler {
            var data = Data()
            data.reserveCapacity(min(maximumBytes, 65_536))
            for try await byte in bytes {
                guard data.count < maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
                data.append(byte)
                if data.count % 16_384 == 0 { try Task.checkCancellation() }
            }
            try Task.checkCancellation()
            return (data, response)
        } onCancel: { bytes.task.cancel() }
    }
}
