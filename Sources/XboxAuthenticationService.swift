import AuthenticationServices
import Combine
import Foundation
import UIKit

struct XboxAccountProfile: Equatable, Identifiable {
    let id: String
    let gamertag: String
    let userHash: String
}

enum XboxAuthenticationError: LocalizedError {
    case invalidResponse
    case serverRejected(Int, String)
    case missingValue(String)
    case invalidRedirect
    case stateMismatch
    case userCancelled
    case sessionUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Microsoft returned an invalid authentication response."
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
final class XboxAuthenticationService: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
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
    @Published private(set) var availableRegions: [String] = []
    @Published var errorMessage: String?

    private let urlSession: URLSession
    private var webAuthenticationSession: ASWebAuthenticationSession?
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

    func signIn() async throws {
        guard !isAuthenticating else { return }
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

            let pkce = try PKCEChallenge.make()
            statusMessage = "Connecting to Microsoft…"
            let (authorizationURL, sessionID) = try await beginSisuAuthentication(
                deviceToken: deviceToken,
                challenge: pkce
            )

            statusMessage = "Waiting for Microsoft sign-in…"
            let callbackURL = try await openMicrosoftSignIn(authorizationURL)
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
            account = profile

            statusMessage = "Preparing Xbox Cloud Gaming…"
            let streamingXSTS = try await requestXSTS(userToken: sisu.userToken, relyingParty: "http://gssv.xboxlive.com/", using: key)
            let streamInfo = try await requestCloudStreamingToken(xstsToken: streamingXSTS)
            try SecureTokenStore.save(streamInfo.gsToken, account: "xbl.cloud-stream-token")
            availableRegions = streamInfo.regions
            try SecureTokenStore.save(profile.gamertag, account: "xbl.profile-gamertag")
            try SecureTokenStore.save(profile.id, account: "xbl.profile-xuid")
            try SecureTokenStore.save(profile.userHash, account: "xbl.profile-user-hash")
            statusMessage = "Signed in — Xbox Cloud token ready"
        } catch {
            statusMessage = "Sign-in failed"
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func signOut() {
        let keys = [
            "xbl.proof-key", "xbl.user-access-token", "xbl.user-refresh-token",
            "xbl.sisu-user-token", "xbl.sisu-title-token", "xbl.sisu-authorization-token",
            "xbl.cloud-stream-token", "xbl.profile-gamertag", "xbl.profile-xuid",
            "xbl.profile-user-hash"
        ]
        for key in keys { try? SecureTokenStore.delete(account: key) }
        account = nil
        availableRegions = []
        statusMessage = "Not signed in"
        errorMessage = nil
        proofKey = nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? UIWindow()
    }

    private func restoreSavedProfile() {
        guard
            let gamertag = try? SecureTokenStore.load(account: "xbl.profile-gamertag"),
            let xuid = try? SecureTokenStore.load(account: "xbl.profile-xuid"),
            let userHash = try? SecureTokenStore.load(account: "xbl.profile-user-hash")
        else { return }
        account = XboxAccountProfile(id: xuid, gamertag: gamertag, userHash: userHash)
        statusMessage = "Xbox account saved"
    }

    private func openMicrosoftSignIn(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: Constants.redirectScheme) { [weak self] callback, error in
                self?.webAuthenticationSession = nil
                if let error {
                    if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        continuation.resume(throwing: XboxAuthenticationError.userCancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let callback else {
                    continuation.resume(throwing: XboxAuthenticationError.invalidRedirect)
                    return
                }
                continuation.resume(returning: callback)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            webAuthenticationSession = session
            guard session.start() else {
                webAuthenticationSession = nil
                continuation.resume(throwing: XboxAuthenticationError.sessionUnavailable)
                return
            }
        }
    }

    private func requestDeviceToken(using key: XBLProofKey) async throws -> String {
        let url = URL(string: "https://device.auth.xboxlive.com/device/authenticate")!
        let deviceID = UUID().uuidString.uppercased()
        let payload: [String: Any] = [
            "Properties": [
                "AuthMethod": "ProofOfPossession",
                "Id": "{\(deviceID)}",
                "DeviceType": "Android",
                "SerialNumber": "{\(UUID().uuidString.uppercased())}",
                "Version": "15.0",
                "ProofKey": [
                    "use": "sig", "alg": "ES256", "kty": "EC", "crv": "P-256",
                    "x": key.jwkX, "y": key.jwkY
                ]
            ],
            "RelyingParty": "http://auth.xboxlive.com",
            "TokenType": "JWT"
        ]
        let data = try await signedJSONRequest(url: url, payload: payload, using: key)
        return try requiredString(data, path: ["Token"])
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
        return SisuAuthorization(
            userToken: try string(user, "Token"),
            titleToken: try string(title, "Token"),
            authorizationToken: try string(authorization, "Token"),
            gamertag: (first["mgt"] as? String) ?? (first["gtg"] as? String) ?? "Xbox Player",
            xboxUserID: (first["xid"] as? String) ?? "",
            userHash: (first["uhs"] as? String) ?? ""
        )
    }

    private func requestXSTS(userToken: String, relyingParty: String, using key: XBLProofKey) async throws -> String {
        let url = URL(string: "https://xsts.auth.xboxlive.com/xsts/authorize")!
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
        let regions = regionObjects.compactMap { $0["name"] as? String }
        return CloudStreamingToken(gsToken: try string(object, "gsToken"), regions: regions)
    }

    private func signedJSONRequest(url: URL, payload: [String: Any], using key: XBLProofKey) async throws -> Data {
        try await signedJSONRequestWithResponse(url: url, payload: payload, using: key).0
    }

    private func signedJSONRequestWithResponse(url: URL, payload: [String: Any], using key: XBLProofKey) async throws -> (Data, URLResponse) {
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let signature = try key.signatureHeader(url: url, authorizationToken: "", body: body)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
            let message = (try? jsonObject(data)["message"] as? String) ?? "The Xbox service rejected the request."
            throw XboxAuthenticationError.serverRejected(http.statusCode, message)
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
    let regions: [String]
}
