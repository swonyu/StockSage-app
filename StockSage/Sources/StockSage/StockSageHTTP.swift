import Foundation

/// Shared bounded body reader for model/evidence clients. Callers own host/policy checks.
enum StockSageHTTP {
    nonisolated final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    @concurrent nonisolated static func data(for request: URLRequest, session: URLSession,
                                           maximumBytes: Int) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
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
