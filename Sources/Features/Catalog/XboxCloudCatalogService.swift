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
    private let httpClient: XboxHTTPClient

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
        self.httpClient = XboxHTTPClient(session: urlSession)
    }

    func fetchCloudGames() async throws -> [CloudGame] {
        let response: XboxCloudTitlesResponse = try await send(
            makeRegionRequest(path: "v2/titles", method: "GET")
        )
        return await mapGames(response.results.filter { $0.details?.hasEntitlement == true })
    }

    func fetchRecentlyPlayed(limit: Int = 25) async throws -> [CloudGame] {
        let safeLimit = min(max(limit, 1), 50)
        let response: XboxCloudTitlesResponse = try await send(
            makeRegionRequest(path: "v2/titles/mru?mr=\(safeLimit)", method: "GET")
        )
        return await mapGames(response.results)
    }

    private func mapGames(_ titles: [XboxCloudTitle]) async -> [CloudGame] {
        // Xbox's catalog endpoint is keyed by StoreId (the same value as
        // details.productId), not by the Xbox titleId.
        let productIDs = Array(Set(titles.compactMap { title -> String? in
            guard let value = title.details?.productId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }))
        let metadata = (try? await fetchProductMetadata(titleIDs: productIDs)) ?? [:]

        return titles.map { item in
            let productID = item.details?.productId?.trimmingCharacters(in: .whitespacesAndNewlines)
            let product = productID.flatMap { id in
                metadata[id] ?? metadata.first(where: {
                    $0.key.caseInsensitiveCompare(id) == .orderedSame
                })?.value
            }
            let artworkURL = normalizedArtworkURL(
                product?.imageTile?.url
                    ?? product?.imagePoster?.url
                    ?? product?.imageHero?.url
                    ?? product?.imageSuperHero?.url
            )
            let backgroundArtworkURL = normalizedArtworkURL(
                product?.imageHero?.url
                    ?? product?.imageSuperHero?.url
                    ?? product?.imagePoster?.url
                    ?? product?.imageTile?.url
            )
            return CloudGame(
                id: item.titleId,
                title: product?.productTitle
                    ?? item.details?.name
                    ?? item.titleId.replacingOccurrences(of: "_", with: " "),
                artworkURL: artworkURL,
                backgroundArtworkURL: backgroundArtworkURL,
                supportsCloudPlay: item.details?.hasEntitlement ?? false
            )
        }
    }

    /// Xbox catalog payloads can contain protocol-relative image URLs. AsyncImage
    /// needs an absolute URL, so normalize those before passing them to SwiftUI.
    private func normalizedArtworkURL(_ rawValue: String?) -> URL? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.hasPrefix("//") {
            return URL(string: "https:\\(value)")
        }
        if value.lowercased().hasPrefix("http://") {
            return URL(string: "https://" + value.dropFirst("http://".count))
        }
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            return nil
        }
        return url
    }

    private func fetchProductMetadata(titleIDs: [String]) async throws -> [String: XboxProductMetadata] {
        let uniqueIDs = Array(Set(titleIDs.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }))
        guard !uniqueIDs.isEmpty else { return [:] }
        var result: [String: XboxProductMetadata] = [:]

        // Keep catalog metadata requests reasonably sized for mobile networks.
        for start in stride(from: 0, to: uniqueIDs.count, by: 40) {
            let end = min(start + 40, uniqueIDs.count)
            let batch = Array(uniqueIDs[start..<end])
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
            request.setValue("26.1.97", forHTTPHeaderField: "calling-app-version")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["Products": batch])

            // Prefer one efficient batch request. If Xbox rejects the batch or
            // omits individual records, retry only the missing products using
            // the same single-product request pattern used by Better xCloud.
            do {
                let batchResult: XboxProductMetadataResponse = try await send(request)
                result.merge(batchResult.products) { _, new in new }
            } catch {
                // Fall through to per-product recovery below.
            }

            let missingIDs = batch.filter { requestedID in
                !result.keys.contains {
                    $0.caseInsensitiveCompare(requestedID) == .orderedSame
                }
            }
            for productID in missingIDs {
                var fallbackRequest = request
                fallbackRequest.httpBody = try JSONSerialization.data(
                    withJSONObject: ["Products": [productID]]
                )
                let singleResult: XboxProductMetadataResponse? = try? await send(fallbackRequest)
                if let singleResult {
                    result.merge(singleResult.products) { _, new in new }
                }
            }
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
        let result = try await httpClient.execute(request)
        let data = result.data
        let response: URLResponse = result.response
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
        let name: String?
        let hasEntitlement: Bool?
        let supportedInputTypes: [String]?
        let programs: [String]?
        let userPrograms: [String]?
        let userSubscriptions: [String]?
    }
}

private struct XboxProductMetadataResponse: Decodable {
    let products: [String: XboxProductMetadata]

    init(from decoder: Decoder) throws {
        // Xbox currently returns { "Products": { "<StoreId>": { ... } } }.
        // Also accept array and casing variants so a response shape change
        // cannot silently discard every artwork record.
        if var array = try? decoder.unkeyedContainer() {
            products = try Self.decodeArray(from: &array)
            return
        }

        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        if let productsKey = container.allKeys.first(where: {
            $0.stringValue.caseInsensitiveCompare("Products") == .orderedSame
        }) {
            let nested = try container.superDecoder(forKey: productsKey)
            products = try Self.decodeProducts(from: nested)
        } else {
            products = try Self.decodeDictionary(from: decoder)
        }
    }

    private static func decodeProducts(from decoder: Decoder) throws -> [String: XboxProductMetadata] {
        if var array = try? decoder.unkeyedContainer() {
            return try decodeArray(from: &array)
        }
        return try decodeDictionary(from: decoder)
    }

    private static func decodeArray(
        from array: inout UnkeyedDecodingContainer
    ) throws -> [String: XboxProductMetadata] {
        var decoded: [String: XboxProductMetadata] = [:]
        while !array.isAtEnd {
            let product = try array.decode(XboxProductMetadata.self)
            if let id = product.productID, !id.isEmpty {
                decoded[id] = product
            }
        }
        return decoded
    }

    private static func decodeDictionary(from decoder: Decoder) throws -> [String: XboxProductMetadata] {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var decoded: [String: XboxProductMetadata] = [:]
        for key in container.allKeys {
            guard let product = try? container.decode(XboxProductMetadata.self, forKey: key) else {
                continue
            }
            // Keep the response dictionary key (the normal Xbox format) and
            // also index by StoreId/ProductId when the payload supplies one.
            decoded[key.stringValue] = product
            if let id = product.productID, !id.isEmpty {
                decoded[id] = product
            }
        }
        return decoded
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private struct XboxProductMetadata: Decodable {
    let productID: String?
    let productTitle: String?
    let imageHero: XboxCatalogImage?
    let imageSuperHero: XboxCatalogImage?
    let imageTile: XboxCatalogImage?
    let imagePoster: XboxCatalogImage?

    enum CodingKeys: String, CodingKey {
        case productID = "ProductId"
        case storeID = "StoreId"
        case productTitle = "ProductTitle"
        case displayName = "DisplayName"
        case title = "Title"
        case name = "Name"
        case imageHero = "Image_Hero"
        case imageSuperHero = "Image_SuperHero"
        case imageTile = "Image_Tile"
        case imagePoster = "Image_Poster"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        productID = try container.decodeIfPresent(String.self, forKey: .storeID)
            ?? container.decodeIfPresent(String.self, forKey: .productID)
        productTitle = try container.decodeIfPresent(String.self, forKey: .productTitle)
            ?? container.decodeIfPresent(String.self, forKey: .displayName)
            ?? container.decodeIfPresent(String.self, forKey: .title)
            ?? container.decodeIfPresent(String.self, forKey: .name)
        imageHero = try container.decodeIfPresent(XboxCatalogImage.self, forKey: .imageHero)
        imageSuperHero = try container.decodeIfPresent(XboxCatalogImage.self, forKey: .imageSuperHero)
        imageTile = try container.decodeIfPresent(XboxCatalogImage.self, forKey: .imageTile)
        imagePoster = try container.decodeIfPresent(XboxCatalogImage.self, forKey: .imagePoster)
    }
}

private struct XboxCatalogImage: Decodable {
    let url: String?

    enum CodingKeys: String, CodingKey {
        case url = "URL"
        case lowercaseURL = "url"
    }

    init(from decoder: Decoder) throws {
        if let singleValue = try? decoder.singleValueContainer(),
           let value = try? singleValue.decode(String.self) {
            url = value
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decodeIfPresent(String.self, forKey: .url)
            ?? container.decodeIfPresent(String.self, forKey: .lowercaseURL)
    }
}
