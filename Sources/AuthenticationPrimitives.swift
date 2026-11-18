import CryptoKit
import Foundation
import Security

enum AuthenticationPrimitiveError: Error, LocalizedError {
    case secureRandomFailure(OSStatus)
    case invalidPublicKey
    case invalidUTF8
    case keychainFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .secureRandomFailure(let status):
            return "Secure random generation failed (\(status))."
        case .invalidPublicKey:
            return "The generated P-256 public key was invalid."
        case .invalidUTF8:
            return "The stored token was not valid UTF-8."
        case .keychainFailure(let status):
            return "Keychain operation failed (\(status))."
        }
    }
}

/// PKCE values for a single Microsoft sign-in attempt.
/// Keep the verifier and state in memory until the redirect is validated.
struct PKCEChallenge {
    let verifier: String
    let challenge: String
    let state: String

    static func make() throws -> PKCEChallenge {
        let verifier = try secureRandom(count: 32).base64URL
        let state = try secureRandom(count: 64).base64URL
        let digest = SHA256.hash(data: Data(verifier.utf8))

        return PKCEChallenge(
            verifier: verifier,
            challenge: Data(digest).base64URL,
            state: state
        )
    }

    func validates(returnedState: String) -> Bool {
        guard returnedState.utf8.count == state.utf8.count else { return false }

        // Compare bytes without an early exit to avoid leaking the mismatch position.
        return zip(state.utf8, returnedState.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// P-256 proof key used to sign Xbox Live proof-of-possession requests.
/// Its raw private representation is stored only in the app's device-only Keychain item
/// so the same key can be restored for silent token renewal.
struct XBLProofKey {
    private let privateKey: P256.Signing.PrivateKey

    init() {
        privateKey = P256.Signing.PrivateKey()
    }

    init(rawRepresentation: Data) throws {
        privateKey = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    }

    var privateKeyRepresentation: Data {
        privateKey.rawRepresentation
    }

    private var publicCoordinates: Data {
        // P-256 X9.63 representation is 0x04 || X(32 bytes) || Y(32 bytes).
        Data(privateKey.publicKey.rawRepresentation.dropFirst())
    }

    var jwkX: String {
        Data(publicCoordinates.prefix(32)).base64URL
    }

    var jwkY: String {
        Data(publicCoordinates.suffix(32)).base64URL
    }

    /// Creates the Xbox Live Signature header for a POST request.
    /// The signed payload follows the XAL format documented by the XStreaming
    /// iOS reference: version, Windows timestamp, method, URL path,
    /// authorization token, and exact request body, separated by NUL bytes.
    func signatureHeader(
        url: URL,
        authorizationToken: String,
        body: Data,
        date: Date = Date()
    ) throws -> String {
        let path = url.path
        // XStreaming's Android XalManager parses the JSON body and serializes
        // its JsonObject with Gson before signing. Gson sorts object keys.
        // Keep the wire body untouched, but sign the same canonical JSON bytes.
        let signingBody = try Self.canonicalJSONBody(body)
        // XStreaming computes Windows time from whole Unix seconds.
        let unixSeconds = Int64(date.timeIntervalSince1970)
        let windowsTicks = UInt64(unixSeconds + 11_644_473_600) * 10_000_000

        var signedMessage = Data()
        signedMessage.appendBigEndian(UInt32(1))
        signedMessage.append(0)
        signedMessage.appendBigEndian(windowsTicks)
        signedMessage.append(0)
        signedMessage.append(contentsOf: "POST".utf8)
        signedMessage.append(0)
        signedMessage.append(contentsOf: path.utf8)
        signedMessage.append(0)
        signedMessage.append(contentsOf: authorizationToken.utf8)
        signedMessage.append(0)
        signedMessage.append(signingBody)
        signedMessage.append(0)

        let signature = try privateKey.signature(for: signedMessage).rawRepresentation

        var header = Data()
        header.appendBigEndian(UInt32(1))
        header.appendBigEndian(windowsTicks)
        header.append(signature)
        return header.base64EncodedString()
    }

    private static func canonicalJSONBody(_ body: Data) throws -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: body),
              JSONSerialization.isValidJSONObject(object) else {
            return body
        }
        // Gson JsonObject serialization in XStreaming uses lexicographically
        // ordered object members and compact JSON without HTML escaping.
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}

/// Minimal Keychain storage for opaque auth/streaming tokens.
/// Callers should store only the token values they need and never log them.
enum SecureTokenStore {
    private static var service: String {
        Bundle.main.bundleIdentifier ?? "com.angkonglucio.xcloudpro"
    }

    static func save(_ token: String, account: String) throws {
        let data = Data(token.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(baseQuery as CFDictionary, updates as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw AuthenticationPrimitiveError.keychainFailure(status)
        }

        var insertQuery = baseQuery
        updates.forEach { insertQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(insertQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AuthenticationPrimitiveError.keychainFailure(addStatus)
        }
    }

    static func load(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw AuthenticationPrimitiveError.keychainFailure(status)
        }
        guard let token = String(data: data, encoding: .utf8) else {
            throw AuthenticationPrimitiveError.invalidUTF8
        }
        return token
    }

    static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthenticationPrimitiveError.keychainFailure(status)
        }
    }
}

private func secureRandom(count: Int) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    guard status == errSecSuccess else {
        throw AuthenticationPrimitiveError.secureRandomFailure(status)
    }
    return Data(bytes)
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
