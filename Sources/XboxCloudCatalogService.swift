import Foundation

enum XboxCloudCatalogError: Error, LocalizedError {
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The Xbox cloud catalog returned an invalid response."
        case .httpStatus(let status):
            return "The Xbox cloud catalog request failed (HTTP \(status))."
        }
    }
}

/// Fetches Xbox Cloud Gaming catalog and recent-played entries using the
/// region URL and cloud streaming token supplied by the authentication layer.
final class XboxCloudCatalogService {
    private let regionBaseURL: URL
    private let gsToken: String
    private let market: String
    private let language: String
    private let urlSession: URLSession

    init(
        regionBaseURL: URL,
        gsToken: String,
        market: String = "US",
        language: String = "en-US",
        urlSession: URLSession = .shared
    ) throws {
        guard regionBaseURL.scheme?.lowercased() == "https",
              regionBaseURL.host != nil else {
            throw XboxCloudCatalogError.invalidResponse
        }
        self.regionBaseURL = regionBaseURL
        self.gsToken = gsToken
        self.market = market
        self.language = language
        self.urlSession = urlSession
    }

    func fetchCloudGames() async throws -> [CloudGame] {
        let response: XboxCloudTitlesResponse = try await send(
            makeRegionRequest(path: "v2/titles", method: "GET")
        )
        return await mapGames(response.results)
    }

    func fetchRecentlyPlayed(limit: Int = 25) async throws -> [CloudGame] {
        let safeLimit = min(max(limit, 1), 50)
        let response: XboxCloudTitlesResponse = try await send(
            makeRegionRequest(path: "v2/titles/mru?mr=\(safeLimit)", method: "GET")
        )
        return await mapGames(response.results)
    }

    private func mapGames(_ titles: [XboxCloudTitle]) async -> [CloudGame] {
        // The catalog product endpoint expects product IDs, not Xbox title IDs.
        let productIDs = titles.compactMap { $0.details?.productId }
        let metadata = (try? await fetchProductMetadata(titleIDs: productIDs)) ?? [:]

        return titles.map { item in
            let productID = item.details?.productId ?? item.titleId
            let artworkURL = (
                metadata[productID]?.imageHero?.url
                    ?? metadata[productID]?.imageTile?.url
            ).flatMap(URL.init(string:))
            return CloudGame(
                id: item.titleId,
                title: metadata[productID]?.productTitle
                    ?? item.titleId.replacingOccurrences(of: "_", with: " "),
                artworkURL: artworkURL,
                supportsCloudPlay: item.details?.hasEntitlement ?? false
            )
        }
    }

    private func fetchProductMetadata(titleIDs: [String]) async throws -> [String: XboxProductMetadata] {
        guard !titleIDs.isEmpty else { return [:] }
        var result: [String: XboxProductMetadata] = [:]

        // Keep catalog metadata requests reasonably sized for mobile networks.
        for start in stride(from: 0, to: titleIDs.count, by: 40) {
            let end = min(start + 40, titleIDs.count)
            let batch = Array(titleIDs[start..<end])
            var components = URLComponents(string: "https://catalog.gamepass.com/v3/products")
            components?.queryItems = [
                URLQueryItem(name: "market", value: market),
                URLQueryItem(name: "language", value: language),
                URLQueryItem(name: "hydration", value: "RemoteHighSapphire0")
            ]
            guard let url = components?.url else {
                throw XboxCloudCatalogError.invalidResponse
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("0", forHTTPHeaderField: "ms-cv")
            request.setValue("Xbox Cloud Gaming Web", forHTTPHeaderField: "calling-app-name")
            request.setValue("21.0.0", forHTTPHeaderField: "calling-app-version")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["Products": batch])

            let batchResult: XboxProductMetadataResponse = try await send(request)
            result.merge(batchResult.products) { _, new in new }
        }
        return result
    }

    private func makeRegionRequest(path: String, method: String) -> URLRequest {
        let url: URL
        if let components = URLComponents(string: path), components.scheme != nil {
            url = components.url ?? regionBaseURL
        } else if path.contains("?"),
                  let components = URLComponents(string: path),
                  let relativePath = components.path.removingPercentEncoding {
            var base = regionBaseURL
            for part in relativePath.split(separator: "/") {
                base.appendPathComponent(String(part))
            }
            var merged = URLComponents(url: base, resolvingAgainstBaseURL: false)
            merged?.queryItems = components.queryItems
            url = merged?.url ?? base
        } else {
            url = path.split(separator: "/").reduce(regionBaseURL) {
                $0.appendingPathComponent(String($1))
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(gsToken)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw XboxCloudCatalogError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw XboxCloudCatalogError.httpStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw XboxCloudCatalogError.invalidResponse
        }
    }
}

private struct XboxCloudTitlesResponse: Decodable {
    let totalItems: Int?
    let results: [XboxCloudTitle]
}

private struct XboxCloudTitle: Decodable {
    let titleId: String
    let details: Details?

    struct Details: Decodable {
        let productId: String?
        let hasEntitlement: Bool?
        let supportedInputTypes: [String]?
        let programs: [String]?
        let userPrograms: [String]?
        let userSubscriptions: [String]?
    }
}

private struct XboxProductMetadataResponse: Decodable {
    let products: [String: XboxProductMetadata]

    enum CodingKeys: String, CodingKey {
        case products = "Products"
    }
}

private struct XboxProductMetadata: Decodable {
    let productTitle: String?
    let imageHero: XboxCatalogImage?
    let imageTile: XboxCatalogImage?

    enum CodingKeys: String, CodingKey {
        case productTitle = "ProductTitle"
        case imageHero = "Image_Hero"
        case imageTile = "Image_Tile"
    }
}

private struct XboxCatalogImage: Decodable {
    let url: String?

    enum CodingKeys: String, CodingKey {
        case url = "URL"
    }
}
