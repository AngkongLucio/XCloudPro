import Combine
import Foundation
import UIKit

struct XboxAuthorizationRequest: Identifiable {
    let id = UUID()
    let url: URL
}

struct XboxAccountProfile: Equatable, Identifiable {
    let id: String
    let gamertag: String
    let userHash: String
}

struct XboxCloudRegion: Codable, Equatable, Identifiable {
    private static let metadata: [String: (displayName: String, continent: String)] = [
        "EASTUS": ("East US", "North America"),
        "EASTUS2": ("East US 2", "North America"),
        "NORTHCENTRALUS": ("North Central US", "North America"),
        "SOUTHCENTRALUS": ("South Central US", "North America"),
        "WESTUS": ("West US", "North America"),
        "WESTUS2": ("West US 2", "North America"),
        "WESTUS3": ("West US 3", "North America"),
        "MEXICOCENTRAL": ("Mexico Central", "North America"),
        "BRAZILSOUTH": ("Brazil South", "South America"),
        "CHILECENTRAL": ("Chile Central", "South America"),
        "JAPANEAST": ("Japan East", "Asia"),
        "KOREACENTRAL": ("Korea Central", "Asia"),
        "CENTRALINDIA": ("Central India", "Asia"),
        "SOUTHINDIA": ("South India", "Asia"),
        "AUSTRALIAEAST": ("Australia East", "Australia"),
        "AUSTRALIASOUTHEAST": ("Australia South East", "Australia"),
        "SWEDENCENTRAL": ("Sweden Central", "Europe"),
        "UKSOUTH": ("UK South", "Europe"),
        "WESTEUROPE": ("West Europe", "Europe")
    ]

    let name: String
    let baseURI: URL
    let isDefault: Bool
    var id: String { name }

    var shortName: String {
        baseURI.host?
            .split(separator: ".")
            .first
            .map(String.init)?
            .uppercased() ?? name.uppercased()
    }

    var displayName: String {
        Self.metadata[name.uppercased()]?.displayName
            ?? Self.metadata[shortName]?.displayName
            ?? name
    }

    var continentName: String {
        Self.metadata[name.uppercased()]?.continent
            ?? Self.metadata[shortName]?.continent
            ?? "Other"
    }

    var pickerTitle: String {
        "\(shortName) — \(displayName)"
    }
}

enum XboxAuthenticationError: LocalizedError {
    case invalidResponse
    case invalidEmail
    case serverRejected(Int, String)
    case missingValue(String)
    case invalidRedirect
    case stateMismatch
    case userCancelled
    case sessionUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Microsoft returned an invalid authentication response."
        case .invalidEmail: return "Enter your Microsoft email address to continue."
        case .serverRejected(let code, let message): return "Xbox authentication failed (HTTP \(code)): \(message)"
        case .missingValue(let name): return "The Xbox authentication response is missing \(name)."
        case .invalidRedirect: return "The Microsoft sign-in redirect was invalid."
        case .stateMismatch: return "The sign-in state did not match. Please try again."
        case .userCancelled: return "Microsoft sign-in was cancelled."
        case .sessionUnavailable: return "The secure Microsoft sign-in window could not be opened."
        }
    }
}

/// Native Microsoft/Xbox XAL sign-in. Protocol constants follow the public
/// XStreaming iOS authentication reference; no password is collected by XCloudPro.
@MainActor
final class XboxAuthenticationService: NSObject, ObservableObject, NSObjectProtocol {
    private enum Constants {
        static let appID = "000000004c20a908"
        static let titleID = "328178078"
        static let redirectURI = "ms-xal-000000004c20a908://auth"
        static let redirectScheme = "ms-xal-000000004c20a908"
        static let userScope = "service::user.auth.xboxlive.com::MBI_SSL"
        static let retailSandbox = "RETAIL"
    }

    @Published private(set) var account: XboxAccountProfile?
    @Published private(set) var isAuthenticating = false
    @Published private(set) var statusMessage = "Not signed in"
    @Published private(set) var availableRegions: [XboxCloudRegion] = []
    @Published var selectedRegionName: String? {
        didSet {
            if let selectedRegionName {
                UserDefaults.standard.set(selectedRegionName, forKey: "xbl.selected-region")
            } else {
                UserDefaults.standard.removeObject(forKey: "xbl.selected-region")
            }
        }
    }
    @Published private(set) var cloudTokenExpiry: Date?
    @Published var errorMessage: String?

    private let urlSession: URLSession
    @Published var authorizationRequest: XboxAuthorizationRequest?
    private var authorizationContinuation: CheckedContinuation<URL, Error>?
    private var proofKey: XBLProofKey?

    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.urlSession = URLSession(configuration: configuration)
        super.init()
        restoreSavedProfile()
    }

    func signIn(email: String) async throws {
        guard !isAuthenticating else { return }
        let emailHint = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard emailHint.contains("@"), emailHint.split(separator: "@").count == 2 else {
            throw XboxAuthenticationError.invalidEmail
        }
        isAuthenticating = true
        errorMessage = nil
        statusMessage = "Preparing secure sign-in…"
        defer { isAuthenticating = false }

        do {
            let key = XBLProofKey()
            proofKey = key
            try SecureTokenStore.save(key.privateKeyRepresentation.base64EncodedString(), account: "xbl.proof-key")

            statusMessage = "Preparing Xbox device authorization…"
            let deviceToken = try await requestDeviceToken(using: key)
            try SecureTokenStore.save(deviceToken, account: "xbl.device-token")

            let pkce = try PKCEChallenge.make()
            statusMessage = "Connecting to Microsoft…"
            let (authorizationURL, sessionID) = try await beginSisuAuthentication(
                deviceToken: deviceToken,
                challenge: pkce
            )

            statusMessage = "Waiting for Microsoft sign-in…"
            let hintedURL = try microsoftSignInURL(authorizationURL, email: emailHint)
            let callbackURL = try await openMicrosoftSignIn(hintedURL)
            guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                  let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value,
                  let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                throw XboxAuthenticationError.invalidRedirect
            }
            guard pkce.validates(returnedState: returnedState) else {
                throw XboxAuthenticationError.stateMismatch
            }

            statusMessage = "Verifying Microsoft account…"
            let userToken = try await exchangeAuthorizationCode(code, verifier: pkce.verifier)
            try SecureTokenStore.save(userToken.accessToken, account: "xbl.user-access-token")
            try SecureTokenStore.save(userToken.refreshToken, account: "xbl.user-refresh-token")

            statusMessage = "Authorizing Xbox profile…"
            let sisu = try await requestSisuAuthorization(
                userAccessToken: userToken.accessToken,
                deviceToken: deviceToken,
                using: key,
                sessionID: sessionID
            )
            try SecureTokenStore.save(sisu.userToken, account: "xbl.sisu-user-token")
            try SecureTokenStore.save(sisu.titleToken, account: "xbl.sisu-title-token")
            try SecureTokenStore.save(sisu.authorizationToken, account: "xbl.sisu-authorization-token")

            let profile = XboxAccountProfile(
                id: sisu.xboxUserID,
                gamertag: sisu.gamertag,
                userHash: sisu.userHash
            )

            statusMessage = "Preparing Xbox Cloud Gaming…"
            let streamingXSTS = try await requestXSTS(userToken: sisu.userToken, relyingParty: "http://gssv.xboxlive.com/", using: key)
            let streamInfo = try await requestCloudStreamingToken(xstsToken: streamingXSTS)
            try SecureTokenStore.save(streamInfo.gsToken, account: "xbl.cloud-stream-token")
            cloudTokenExpiry = Date().addingTimeInterval(TimeInterval(streamInfo.durationInSeconds))
            try SecureTokenStore.save(String(cloudTokenExpiry!.timeIntervalSince1970), account: "xbl.cloud-token-expiry")
            availableRegions = streamInfo.regions
            try saveRegions(streamInfo.regions)
            // Keep the user's manual region choice across sign-ins. Nil means Xbox default.
            if let savedRegionName = UserDefaults.standard.string(forKey: "xbl.selected-region"),
               streamInfo.regions.contains(where: { $0.name == savedRegionName }) {
                selectedRegionName = savedRegionName
            } else {
                selectedRegionName = nil
            }
            try SecureTokenStore.save(profile.gamertag, account: "xbl.profile-gamertag")
            try SecureTokenStore.save(profile.id, account: "xbl.profile-xuid")
            try SecureTokenStore.save(profile.userHash, account: "xbl.profile-user-hash")
            account = profile
            statusMessage = "Signed in — Xbox Cloud token ready"
        } catch {
            statusMessage = "Sign-in failed"
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func signOut() {
        let keys = [
            "xbl.proof-key", "xbl.device-token", "xbl.user-access-token", "xbl.user-refresh-token",
            "xbl.sisu-user-token", "xbl.sisu-title-token", "xbl.sisu-authorization-token",
            "xbl.cloud-stream-token", "xbl.cloud-token-expiry", "xbl.cloud-regions", "xbl.profile-gamertag", "xbl.profile-xuid",
            "xbl.profile-user-hash"
        ]
        for key in keys { try? SecureTokenStore.delete(account: key) }
        account = nil
        availableRegions = []
        selectedRegionName = nil
        UserDefaults.standard.removeObject(forKey: "xbl.selected-region")
        cloudTokenExpiry = nil
        statusMessage = "Not signed in"
        errorMessage = nil
        proofKey = nil
    }


    private func restoreSavedProfile() {
        // A cached gamertag alone is not proof of an authenticated Xbox session.
        // Restore the signed-in state only when the native XAL refresh credential,
        // proof key and a cloud token are present; cloudSessionCredentials() will
        // refresh an expired cloud token before streaming starts.
        guard
            let gamertag = try? SecureTokenStore.load(account: "xbl.profile-gamertag"),
            let xuid = try? SecureTokenStore.load(account: "xbl.profile-xuid"),
            let userHash = try? SecureTokenStore.load(account: "xbl.profile-user-hash"),
            let refreshToken = try? SecureTokenStore.load(account: "xbl.user-refresh-token"),
            let proofKey = try? SecureTokenStore.load(account: "xbl.proof-key"),
            !refreshToken.isEmpty,
            !proofKey.isEmpty
        else { return }
        account = XboxAccountProfile(id: xuid, gamertag: gamertag, userHash: userHash)
        if let raw = try? SecureTokenStore.load(account: "xbl.cloud-regions"),
           let data = Data(base64Encoded: raw),
           let regions = try? JSONDecoder().decode([XboxCloudRegion].self, from: data) {
            availableRegions = regions
        }
        selectedRegionName = UserDefaults.standard.string(forKey: "xbl.selected-region")
        if let rawExpiry = try? SecureTokenStore.load(account: "xbl.cloud-token-expiry"),
           let timestamp = Double(rawExpiry) {
            cloudTokenExpiry = Date(timeIntervalSince1970: timestamp)
        }
        statusMessage = "Xbox account saved"
    }

    var regionContinents: [String] {
        let order = ["Asia", "Australia", "Europe", "North America", "South America", "Other"]
        return order.filter { continent in
            availableRegions.contains(where: { $0.continentName == continent })
        }
    }

    /// Returns a current cloud token and a server region supplied by Xbox.
    /// Credentials are silently refreshed when the streaming token is near expiry.
    func cloudSessionCredentials() async throws -> (gsToken: String, region: XboxCloudRegion) {
        let token = try SecureTokenStore.load(account: "xbl.cloud-stream-token")
        let isFresh = (cloudTokenExpiry ?? .distantPast).timeIntervalSinceNow > 120
        if token == nil || !isFresh || availableRegions.isEmpty {
            try await refreshCloudCredentials()
        }
        guard let gsToken = try SecureTokenStore.load(account: "xbl.cloud-stream-token"),
              let region = availableRegions.first(where: { $0.name == selectedRegionName })
                ?? availableRegions.first(where: { $0.isDefault })
                ?? availableRegions.first else {
            throw XboxAuthenticationError.missingValue("cloud streaming token or region")
        }
        return (gsToken, region)
    }

    /// Xbox Cloud's /connect endpoint expects the Passport console-transfer token,
    /// not the ordinary Microsoft account access token.
    func cloudTransferToken() async throws -> String {
        guard let refreshToken = try SecureTokenStore.load(account: "xbl.user-refresh-token") else {
            throw XboxAuthenticationError.missingValue("Microsoft refresh token")
        }
        let url = URL(string: "https://login.live.com/oauth20_token.srf")!
        let body = formEncoded([
            "client_id": Constants.appID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "service::http://Passport.NET/purpose::PURPOSE_XBOX_CLOUD_CONSOLE_TRANSFER_TOKEN",
            "code": "",
            "code_verifier": "",
            "redirect_uri": ""
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store, must-revalidate, no-cache", forHTTPHeaderField: "Cache-Control")
        let object = try jsonObject(await perform(request))
        if let rotated = object["refresh_token"] as? String, !rotated.isEmpty {
            try SecureTokenStore.save(rotated, account: "xbl.user-refresh-token")
        }
        return try string(object, "access_token")
    }

    private func refreshCloudCredentials() async throws {
        guard let refreshToken = try SecureTokenStore.load(account: "xbl.user-refresh-token") else {
            throw XboxAuthenticationError.missingValue("Microsoft refresh token; sign in again")
        }
        let key: XBLProofKey
        if let proofKey {
            key = proofKey
        } else {
            guard let raw = try SecureTokenStore.load(account: "xbl.proof-key"),
                  let data = Data(base64Encoded: raw) else {
                throw XboxAuthenticationError.missingValue("Xbox proof key; sign in again")
            }
            key = try XBLProofKey(rawRepresentation: data)
            proofKey = key
        }
        // Match XStreaming refresh order: refresh Microsoft user token first,
        // then obtain a fresh device token before Sisu authorization.
        let userToken = try await refreshUserToken(refreshToken)
        try SecureTokenStore.save(userToken.accessToken, account: "xbl.user-access-token")
        try SecureTokenStore.save(userToken.refreshToken, account: "xbl.user-refresh-token")

        let deviceToken = try await requestDeviceToken(using: key)
        try SecureTokenStore.save(deviceToken, account: "xbl.device-token")
        let sisu = try await requestSisuAuthorization(
            userAccessToken: userToken.accessToken,
            deviceToken: deviceToken,
            using: key,
            sessionID: nil
        )
        try SecureTokenStore.save(sisu.userToken, account: "xbl.sisu-user-token")
        try SecureTokenStore.save(sisu.titleToken, account: "xbl.sisu-title-token")
        try SecureTokenStore.save(sisu.authorizationToken, account: "xbl.sisu-authorization-token")
        let xsts = try await requestXSTS(
            userToken: sisu.userToken,
            relyingParty: "http://gssv.xboxlive.com/",
            using: key
        )
        let streamInfo = try await requestCloudStreamingToken(xstsToken: xsts)
        try SecureTokenStore.save(streamInfo.gsToken, account: "xbl.cloud-stream-token")
        cloudTokenExpiry = Date().addingTimeInterval(TimeInterval(streamInfo.durationInSeconds))
        try SecureTokenStore.save(String(cloudTokenExpiry!.timeIntervalSince1970), account: "xbl.cloud-token-expiry")
        availableRegions = streamInfo.regions
        try saveRegions(streamInfo.regions)
        if let selectedRegionName,
           !streamInfo.regions.contains(where: { $0.name == selectedRegionName }) {
            // The selected region disappeared from the refreshed Xbox offering list.
            // Return to automatic/default instead of silently selecting another region.
            self.selectedRegionName = nil
        }
        statusMessage = "Xbox Cloud credentials refreshed"
    }

    private func refreshUserToken(_ refreshToken: String) async throws -> UserOAuthToken {
        let url = URL(string: "https://login.live.com/oauth20_token.srf")!
        let body = formEncoded([
            "client_id": Constants.appID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": Constants.userScope
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store, must-revalidate, no-cache", forHTTPHeaderField: "Cache-Control")
        let object = try jsonObject(await perform(request))
        return UserOAuthToken(
            accessToken: try string(object, "access_token"),
            refreshToken: (object["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? refreshToken
        )
    }

    private func saveRegions(_ regions: [XboxCloudRegion]) throws {
        let data = try JSONEncoder().encode(regions)
        try SecureTokenStore.save(data.base64EncodedString(), account: "xbl.cloud-regions")
    }

    private func microsoftSignInURL(_ url: URL, email: String) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw XboxAuthenticationError.invalidRedirect
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "login_hint" }
        queryItems.append(URLQueryItem(name: "login_hint", value: email))
        components.queryItems = queryItems
        guard let hintedURL = components.url else {
            throw XboxAuthenticationError.invalidRedirect
        }
        return hintedURL
    }

    /// Mirrors XStreaming's embedded WebView and ms-xal redirect callback.
    private func openMicrosoftSignIn(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            guard authorizationContinuation == nil else {
                continuation.resume(throwing: XboxAuthenticationError.sessionUnavailable)
                return
            }
            authorizationContinuation = continuation
            authorizationRequest = XboxAuthorizationRequest(url: url)
        }
    }

    func completeMicrosoftSignIn(_ callbackURL: URL) {
        guard callbackURL.scheme?.lowercased() == Constants.redirectScheme,
              let continuation = authorizationContinuation else { return }
        authorizationContinuation = nil
        authorizationRequest = nil
        continuation.resume(returning: callbackURL)
    }

    func cancelMicrosoftSignIn() {
        guard let continuation = authorizationContinuation else { return }
        authorizationContinuation = nil
        authorizationRequest = nil
        continuation.resume(throwing: XboxAuthenticationError.userCancelled)
    }

    private func requestDeviceToken(using key: XBLProofKey) async throws -> String {
        let url = URL(string: "https://device.auth.xboxlive.com/device/authenticate")!

        // XStreaming retries Device Authenticate on HTTP 400. Keep the retry bounded
        // so a persistent service error cannot loop indefinitely.
        for attempt in 1...2 {
            let deviceID = UUID().uuidString.uppercased()
            let serialNumber = UUID().uuidString.uppercased()
            // Match XStreaming's device-auth JSON byte-for-byte in field order.
            // Interpolated values are UUIDs and base64url JWK coordinates.
            let bodyString = """
            {"Properties":{"AuthMethod":"ProofOfPossession","Id":"{\(deviceID)}","DeviceType":"Android","SerialNumber":"{\(serialNumber)}","Version":"15.0","ProofKey":{"use":"sig","alg":"ES256","kty":"EC","crv":"P-256","x":"\(key.jwkX)","y":"\(key.jwkY)"}},"RelyingParty":"http://auth.xboxlive.com","TokenType":"JWT"}
            """
            let body = Data(bodyString.utf8)

            do {
                let data = try await signedJSONBodyRequest(url: url, body: body, using: key, includeContentType: false)
                return try requiredString(data, path: ["Token"])
            } catch let error as XboxAuthenticationError {
                guard case .serverRejected(let statusCode, let details) = error else {
                    throw error
                }
                if statusCode == 400 && attempt == 1 {
                    continue
                }
                throw XboxAuthenticationError.serverRejected(
                    statusCode,
                    "device-auth attempt \(attempt)/2 | \(details)"
                )
            }
        }

        throw XboxAuthenticationError.invalidResponse
    }

    private func beginSisuAuthentication(deviceToken: String, challenge: PKCEChallenge) async throws -> (URL, String?) {
        let url = URL(string: "https://sisu.xboxlive.com/authenticate")!
        let payload: [String: Any] = [
            "AppId": Constants.appID,
            "TitleId": Constants.titleID,
            "RedirectUri": Constants.redirectURI,
            "DeviceToken": deviceToken,
            "Sandbox": Constants.retailSandbox,
            "TokenType": "code",
            "Offers": [Constants.userScope],
            "Query": [
                "display": "android_phone",
                "code_challenge": challenge.challenge,
                "code_challenge_method": "S256",
                "state": challenge.state
            ]
        ]
        let (data, response) = try await signedJSONRequestWithResponse(url: url, payload: payload, using: proofKey!)
        let object = try jsonObject(data)
        guard let nested = object["data"] as? [String: Any],
              let redirect = nested["MsaOauthRedirect"] as? String,
              let authorizationURL = URL(string: redirect) else {
            throw XboxAuthenticationError.missingValue("Microsoft authorization URL")
        }
        let sessionID = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-sessionid")
        return (authorizationURL, sessionID)
    }

    private func exchangeAuthorizationCode(_ code: String, verifier: String) async throws -> UserOAuthToken {
        let url = URL(string: "https://login.live.com/oauth20_token.srf")!
        let body = formEncoded([
            "client_id": Constants.appID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": Constants.redirectURI,
            "scope": Constants.userScope
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store, must-revalidate, no-cache", forHTTPHeaderField: "Cache-Control")
        let data = try await perform(request)
        let object = try jsonObject(data)
        return UserOAuthToken(
            accessToken: try string(object, "access_token"),
            refreshToken: try string(object, "refresh_token")
        )
    }

    private func requestSisuAuthorization(userAccessToken: String, deviceToken: String, using key: XBLProofKey, sessionID: String?) async throws -> SisuAuthorization {
        let url = URL(string: "https://sisu.xboxlive.com/authorize")!
        var payload: [String: Any] = [
            "AccessToken": "t=" + userAccessToken,
            "AppId": Constants.appID,
            "DeviceToken": deviceToken,
            "Sandbox": Constants.retailSandbox,
            "SiteName": "user.auth.xboxlive.com",
            "UseModernGamertag": true,
            "ProofKey": [
                "use": "sig", "alg": "ES256", "kty": "EC", "crv": "P-256",
                "x": key.jwkX, "y": key.jwkY
            ]
        ]
        if let sessionID { payload["SessionId"] = sessionID }
        let data = try await signedJSONRequest(url: url, payload: payload, using: key)
        let object = try jsonObject(data)
        let user = object["UserToken"] as? [String: Any] ?? [:]
        let title = object["TitleToken"] as? [String: Any] ?? [:]
        let authorization = object["AuthorizationToken"] as? [String: Any] ?? [:]
        let claims = authorization["DisplayClaims"] as? [String: Any] ?? [:]
        let xui = claims["xui"] as? [[String: Any]] ?? []
        let first = xui.first ?? [:]
        guard let xboxUserID = first["xid"] as? String, !xboxUserID.isEmpty,
              let userHash = first["uhs"] as? String, !userHash.isEmpty else {
            throw XboxAuthenticationError.missingValue("Xbox user ID and user hash")
        }
        return SisuAuthorization(
            userToken: try string(user, "Token"),
            titleToken: try string(title, "Token"),
            authorizationToken: try string(authorization, "Token"),
            gamertag: (first["mgt"] as? String) ?? (first["gtg"] as? String) ?? "Xbox Player",
            xboxUserID: xboxUserID,
            userHash: userHash
        )
    }

    private func requestXSTS(
        userToken: String,
        relyingParty: String,
        using key: XBLProofKey
    ) async throws -> String {
        let url = URL(string: "https://xsts.auth.xboxlive.com/xsts/authorize")!
        // Match the current XStreaming iOS XSTS request exactly.
        // The current implementation sends only SandboxId + UserTokens;
        // DeviceToken and TitleToken are not part of this request.
        let payload: [String: Any] = [
            "Properties": [
                "SandboxId": Constants.retailSandbox,
                "UserTokens": [userToken]
            ],
            "RelyingParty": relyingParty,
            "TokenType": "JWT"
        ]
        let data = try await signedJSONRequest(url: url, payload: payload, using: key)
        return try requiredString(data, path: ["Token"])
    }

    private func requestCloudStreamingToken(xstsToken: String) async throws -> CloudStreamingToken {
        do {
            return try await requestCloudStreamingToken(xstsToken: xstsToken, offering: "xgpuweb")
        } catch {
            return try await requestCloudStreamingToken(xstsToken: xstsToken, offering: "xgpuwebf2p")
        }
    }

    private func requestCloudStreamingToken(xstsToken: String, offering: String) async throws -> CloudStreamingToken {
        let url = URL(string: "https://\(offering).gssv-play-prod.xboxlive.com/v2/login/user")!
        let payload: [String: Any] = ["token": xstsToken, "offeringId": offering]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store, must-revalidate, no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("XboxComBrowser", forHTTPHeaderField: "x-gssv-client")
        let data = try await perform(request)
        let object = try jsonObject(data)
        let settings = object["offeringSettings"] as? [String: Any] ?? [:]
        let regionObjects = settings["regions"] as? [[String: Any]] ?? []
        let regions = regionObjects.compactMap { item -> XboxCloudRegion? in
            guard let name = item["name"] as? String,
                  let rawBaseURI = item["baseUri"] as? String,
                  let baseURI = URL(string: rawBaseURI),
                  baseURI.scheme?.lowercased() == "https",
                  baseURI.host != nil else { return nil }
            return XboxCloudRegion(name: name, baseURI: baseURI, isDefault: item["isDefault"] as? Bool ?? false)
        }
        guard !regions.isEmpty else { throw XboxAuthenticationError.missingValue("available cloud regions") }
        return CloudStreamingToken(
            gsToken: try string(object, "gsToken"),
            regions: regions,
            durationInSeconds: object["durationInSeconds"] as? Int ?? 14_400
        )
    }

    private func signedJSONRequest(url: URL, payload: [String: Any], using key: XBLProofKey, includeContentType: Bool = false) async throws -> Data {
        try await signedJSONRequestWithResponse(url: url, payload: payload, using: key, includeContentType: includeContentType).0
    }

    private func signedJSONRequestWithResponse(url: URL, payload: [String: Any], using key: XBLProofKey, includeContentType: Bool = true) async throws -> (Data, URLResponse) {
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return try await signedJSONBodyRequestWithResponse(url: url, body: body, using: key, includeContentType: includeContentType)
    }

    private func signedJSONBodyRequest(url: URL, body: Data, using key: XBLProofKey, includeContentType: Bool) async throws -> Data {
        try await signedJSONBodyRequestWithResponse(url: url, body: body, using: key, includeContentType: includeContentType).0
    }

    private func signedJSONBodyRequestWithResponse(url: URL, body: Data, using key: XBLProofKey, includeContentType: Bool) async throws -> (Data, URLResponse) {
        // Sign the exact byte sequence that URLSession sends as the HTTP body.
        let signature = try key.signatureHeader(url: url, authorizationToken: "", body: body)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        if includeContentType {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        // Match XStreaming Axios defaults: Accept JSON and leave Content-Type unset
        // for signed JSON-string bodies.
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "x-xbl-contract-version")
        request.setValue("no-store, must-revalidate, no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue(signature, forHTTPHeaderField: "Signature")
        return try await performWithResponse(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        try await performWithResponse(request).0
    }

    private func performWithResponse(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw XboxAuthenticationError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            // Report only safe error metadata. Never include response bodies,
            // request payloads, cookies, authorization headers, or token values.
            let endpoint = "\(request.url?.host ?? "unknown-host")\(request.url?.path ?? "")"
            let responseObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let safeMessageKeys = ["message", "Message", "error_description", "error", "Error", "code", "Code", "XErr", "xErr"]
            let serviceMessage = safeMessageKeys
                .compactMap { responseObject[$0] }
                .compactMap { value -> String? in
                    if let text = value as? String { return text }
                    if let number = value as? NSNumber { return number.stringValue }
                    return nil
                }
                .first(where: { !$0.isEmpty })
            let serviceErrorHeader = http.value(forHTTPHeaderField: "x-err")
                ?? http.value(forHTTPHeaderField: "x-xbl-error")
            let requestID = http.value(forHTTPHeaderField: "x-request-id")
                ?? http.value(forHTTPHeaderField: "request-id")
                ?? http.value(forHTTPHeaderField: "x-ms-request-id")
            var details = [endpoint]
            if let serviceMessage { details.append("service: " + String(serviceMessage.prefix(240))) }
            if let serviceErrorHeader { details.append("Xbox error: " + String(serviceErrorHeader.prefix(80))) }
            if let requestID { details.append("request ID: " + String(requestID.prefix(100))) }

            // Device-auth diagnostics are limited to non-secret transport metadata.
            if endpoint == "device.auth.xboxlive.com/device/authenticate" {
                let method = request.httpMethod ?? "unknown"
                let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? "unset"
                let bodySize = request.httpBody?.count ?? 0
                let hasSignature = request.value(forHTTPHeaderField: "Signature") != nil
                let contractVersion = request.value(forHTTPHeaderField: "x-xbl-contract-version") ?? "unset"
                details.append("request: method=\(method), content-type=\(contentType), body-bytes=\(bodySize), signature-present=\(hasSignature), contract=\(contractVersion)")
                if let responseType = http.value(forHTTPHeaderField: "Content-Type") {
                    details.append("response-content-type: " + String(responseType.prefix(100)))
                }
                if let server = http.value(forHTTPHeaderField: "Server") {
                    details.append("server: " + String(server.prefix(80)))
                }
                if let date = http.value(forHTTPHeaderField: "Date") {
                    details.append("server-date: " + String(date.prefix(80)))
                }
                if let msCV = http.value(forHTTPHeaderField: "ms-cv") {
                    details.append("ms-cv: " + String(msCV.prefix(120)))
                }
                if let proxySuccess = http.value(forHTTPHeaderField: "x-proxy-success") {
                    details.append("x-proxy-success: " + String(proxySuccess.prefix(80)))
                }
            }
            if details.count == 1 { details.append("The Xbox service rejected the request without a readable error code.") }
            throw XboxAuthenticationError.serverRejected(http.statusCode, details.joined(separator: " | "))
        }
        return (data, response)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XboxAuthenticationError.invalidResponse
        }
        return object
    }

    private func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String, !value.isEmpty else {
            throw XboxAuthenticationError.missingValue(key)
        }
        return value
    }

    private func requiredString(_ data: Data, path: [String]) throws -> String {
        var current: Any = try jsonObject(data)
        for key in path {
            guard let dictionary = current as? [String: Any], let next = dictionary[key] else {
                throw XboxAuthenticationError.missingValue(path.joined(separator: "."))
            }
            current = next
        }
        guard let value = current as? String, !value.isEmpty else {
            throw XboxAuthenticationError.missingValue(path.joined(separator: "."))
        }
        return value
    }

    private func formEncoded(_ values: [String: String]) -> String {
        var components = URLComponents()
        components.queryItems = values.keys.sorted().map { URLQueryItem(name: $0, value: values[$0]) }
        return components.percentEncodedQuery ?? ""
    }
}

private struct UserOAuthToken {
    let accessToken: String
    let refreshToken: String
}

private struct SisuAuthorization {
    let userToken: String
    let titleToken: String
    let authorizationToken: String
    let gamertag: String
    let xboxUserID: String
    let userHash: String
}

private struct CloudStreamingToken {
    let gsToken: String
    let regions: [XboxCloudRegion]
    let durationInSeconds: Int
}
