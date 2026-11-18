import Foundation

/// Shared transport boundary for Xbox Cloud REST requests.
///
/// Services own endpoint-specific headers, payloads, decoding and error semantics.
/// This layer deliberately does not retry requests or log bodies/headers: retry
/// policy belongs to the endpoint because Xbox auth endpoints have different rules.
struct XboxHTTPResponse {
    let data: Data
    let response: HTTPURLResponse
}

enum XboxHTTPClientError: Error, LocalizedError {
    case nonHTTPResponse

    var errorDescription: String? {
        switch self {
        case .nonHTTPResponse:
            return "The Xbox service returned an invalid HTTP response."
        }
    }
}

final class XboxHTTPClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func execute(_ request: URLRequest) async throws -> XboxHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw XboxHTTPClientError.nonHTTPResponse
        }
        return XboxHTTPResponse(data: data, response: httpResponse)
    }
}
