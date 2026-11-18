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
        "NEWZEALANDNORTH": ("New Zealand North", "Oceania"),
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
    case deviceCodeExpired

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
        case .deviceCodeExpired: return "The Microsoft device code expired. Start sign-in again."
        }
    }
}

/// Native Microsoft/Xbox XAL sign-in. Protocol constants follow the public
/// XStreaming iOS authentication reference; no password is collected by XCloudPro.
@MainActor
final class XboxAuthenticationService: NSObject, ObservableObject {
    private enum Constants {
        static let appID = "000000004c20a908"
        static let titleID = "328178078"
        static let redirectURI = "ms-xal-000000004c20a908://auth"
        static let redirectScheme = "ms-xal-000000004c20a908"
        static let userScope = "service::user.auth.xboxlive.com::MBI_SSL"
        static let retailSandbox = "RETAIL"
        static let msalClientID = "1f907974-e22b-4810-a9de-d9647380c97e"
        static let msalScopes = "xboxlive.signin openid profile offline_access"
    }

    @Published private(set) var account: XboxAccountProfile?
    @Published private(set) var isAuthenticating = false
    @Published private(set) var statusMessage = "Not signed in"
    @Published private(set) var availableRegions: [XboxCloudRegion] = []
    @Published private(set) var cloudAvailabilityMessage: String?
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

    private let httpClient: XboxHTTPClient
    @Published var authorizationRequest: XboxAuthorizationRequest?
    @Published private(set) var deviceCodeRequest: MicrosoftDeviceCode?
    private var deviceCodeCancelled = false
    private var authorizationContinuation: CheckedContinuation<URL, Error>?
    private var proofKey: XBLProofKey?

    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.httpClient = XboxHTTPClient(session: URLSession(configuration: configuration))
        super.init()
        restoreSavedProfile()
    }


    /// XStreaming-style Microsoft Device Code sign-in. This path avoids the
    /// legacy XAL device-auth bootstrap and never asks the app to handle a password.
    func signInWithDeviceCode() async throws {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        deviceCodeCancelled = false
        errorMessage = nil
        statusMessage = "Requesting Microsoft device code…"
        defer {
            isAuthenticating = false
            deviceCodeRequest = nil
        }

        do {
            let challenge = try await requestMicrosoftDeviceCode()
            deviceCodeRequest = challenge
            statusMessage = "Enter the code on Microsoft's device-login page"
            await UIApplication.shared.open(challenge.verificationURL)

            let msaToken = try await pollMicrosoftDeviceCode(challenge)
            try SecureTokenStore.save(msaToken.accessToken, account: "xbl.msal.access-token")
            try SecureTokenStore.save(msaToken.refreshToken, account: "xbl.msal.refresh-token")

            statusMessage = "Exchanging Microsoft token for Xbox authorization…"
            let xboxUserToken = try await authenticateMicrosoftTokenWithXbox(msaToken.accessToken)
            try SecureTokenStore.save(xboxUserToken, account: "xbl.msal.xbox-user-token")

            statusMessage = "Requesting Xbox Cloud credentials…"
            let web = try await requestMSALXSTS(userToken: xboxUserToken, relyingParty: "http://xboxlive.com")
            let home = try await requestMSALXSTS(userToken: xboxUserToken, relyingParty: "http://gssv.xboxlive.com/", requiresProfileClaims: false)
            // Cloud Gaming is optional: Xbox may deny xgpuweb/xgpuwebf2p
            // in unsupported markets while xhome Remote Play remains available.
            let homeInfo = try await requestHomeStreamingToken(xstsToken: home.token)
            let cloudInfo = try? await requestCloudStreamingToken(xstsToken: home.token)
            let homeRegionData = try JSONEncoder().encode(homeInfo.regions)
            try SecureTokenStore.save(homeRegionData.base64EncodedString(), account: "xbl.msal.home-regions")

            let profile = XboxAccountProfile(
                id: web.xboxUserID,
                gamertag: web.gamertag,
                userHash: web.userHash
            )
            try SecureTokenStore.save(web.token, account: "xbl.msal.web-xsts")
            try SecureTokenStore.save(home.token, account: "xbl.msal.home-xsts")
            try SecureTokenStore.save(homeInfo.gsToken, account: "xbl.msal.home-gs-token")
            try SecureTokenStore.save(profile.gamertag, account: "xbl.profile-gamertag")
            try SecureTokenStore.save(profile.id, account: "xbl.profile-xuid")
            try SecureTokenStore.save(profile.userHash, account: "xbl.profile-user-hash")

            let tokenLifetime = min(cloudInfo?.durationInSeconds ?? homeInfo.durationInSeconds, homeInfo.durationInSeconds)
            cloudTokenExpiry = Date().addingTimeInterval(TimeInterval(tokenLifetime))
            try SecureTokenStore.save(String(cloudTokenExpiry!.timeIntervalSince1970), account: "xbl.cloud-token-expiry")
            if let cloudInfo {
                cloudAvailabilityMessage = nil
                try SecureTokenStore.save(cloudInfo.gsToken, account: "xbl.cloud-stream-token")
                availableRegions = cloudInfo.regions
                try saveRegions(cloudInfo.regions)
                if let saved = UserDefaults.standard.string(forKey: "xbl.selected-region"),
                   cloudInfo.regions.contains(where: { $0.name == saved }) {
                    selectedRegionName = saved
                } else {
                    selectedRegionName = nil
                }
            } else {
                try SecureTokenStore.delete(account: "xbl.cloud-stream-token")
                try SecureTokenStore.delete(account: "xbl.cloud-regions")
                availableRegions = []
                selectedRegionName = nil
                cloudAvailabilityMessage = "Microsoft accepted your sign-in, but Xbox denied the Cloud Gaming offering. No cloud regions were returned for this account."
            }
            account = profile
            statusMessage = cloudInfo == nil
                ? "Signed in — Cloud Gaming offering unavailable; Remote Play credentials saved"
                : "Signed in — Microsoft Device Code"
        } catch {
            statusMessage = "Device-code sign-in failed"
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func cancelDeviceCodeSignIn() {
        deviceCodeCancelled = true
        deviceCodeRequest = nil
        statusMessage = "Cancelling Microsoft sign-in…"
    }

    private func requestMicrosoftDeviceCode() async throws -> MicrosoftDeviceCode {
        let url = URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(formEncoded([
            "client_id": Constants.msalClientID,
            "scope": Constants.msalScopes
        ]).utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store, must-revalidate, no-cache", forHTTPHeaderField: "Cache-Control")
        let object = try jsonObject(await perform(request))
        guard let code = object["device_code"] as? String, !code.isEmpty,
              let userCode = object["user_code"] as? String, !userCode.isEmpty,
              let rawURL = object["verification_uri"] as? String,
              let verificationURL = URL(string: rawURL),
              let expiresIn = object["expires_in"] as? Int else {
            throw XboxAuthenticationError.invalidResponse
        }
        return MicrosoftDeviceCode(
            deviceCode: code,
            userCode: userCode,
            verificationURL: verificationURL,
            verificationURLComplete: (object["verification_uri_complete"] as? String).flatMap { URL(string: $0) },
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            interval: max(1, object["interval"] as? Int ?? 5),
            message: object["message"] as? String ?? "Open microsoft.com/devicelogin and enter the code."
        )
    }

    private func pollMicrosoftDeviceCode(_ challenge: MicrosoftDeviceCode) async throws -> UserOAuthToken {
        var interval = challenge.interval
        let url = URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")!
        while Date() < challenge.expiresAt {
            if deviceCodeCancelled { throw XboxAuthenticationError.userCancelled }
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            if deviceCodeCancelled { throw XboxAuthenticationError.userCancelled }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = Data(formEncoded([
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "client_id": Constants.msalClientID,
                "device_code": challenge.deviceCode
            ]).utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("no-store, must-revalidate, no-cache", forHTTPHeaderField: "Cache-Control")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw XboxAuthenticationError.invalidResponse }
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if (200..<300).contains(http.statusCode) {
                return UserOAuthToken(
                    accessToken: try string(object, "access_token"),
                    refreshToken: try string(object, "refresh_token")
                )
            }

            let error = object["error"] as? String ?? "unknown_error"
            switch error {
            case "authorization_pending":
                statusMessage = "Waiting for Microsoft approval…"
                continue
            case "slow_down":
                interval += 5
                continue
            case "authorization_declined", "access_denied":
                throw XboxAuthenticationError.userCancelled
            case "expired_token":
                throw XboxAuthenticationError.deviceCodeExpired
            default:
                let description = object["error_description"] as? String ?? error
                throw XboxAuthenticationError.serverRejected(http.statusCode, "Microsoft device-code token: " + String(description.prefix(180)))
            }
        }
        throw XboxAuthenticationError.deviceCodeExpired
    }

    private func authenticateMicrosoftTokenWithXbox(_ accessToken: String) async throws -> String {
        let url = URL(string: "https://user.auth.xboxlive.com/user/authenticate")!
        let payload: [String: Any] = [
            "Properties": [
                "AuthMethod": "RPS",
                "SiteName": "user.auth.xboxlive.com",
                "RpsTicket": "d=" + accessToken
            ],
            "RelyingParty": "http://auth.xboxlive.com",
            "TokenType": "JWT"
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "x-xbl-contract-version")
        request.setValue("no-store, must-revalidate, no-cache", forHTTPHeaderField: "Cache-Control")
        return try requiredString(await perform(request), path: ["Token"])
    }

    private func requestMSALXSTS(userToken: String, relyingParty: String, requiresProfileClaims: Bool = true) async throws -> MSALXSTSResult {
        let url = URL(string: "https://xsts.auth.xboxlive.com/xsts/authorize")!
        let payload: [String: Any] = [
            "Properties": ["SandboxId": "RETAIL", "UserTokens": [userToken]],
            "RelyingParty": relyingParty,
            "TokenType": "JWT"
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "x-xbl-contract-version")
        request.setValue("no-store, must-revalidate, no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("https://www.xbox.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.xbox.com/", forHTTPHeaderField: "Referer")
        let object = try jsonObject(await perform(request))
        let claims = object["DisplayClaims"] as? [String: Any] ?? [:]
        let xui = claims["xui"] as? [[String: Any]] ?? []
        guard let first = xui.first,
              let userHash = first["uhs"] as? String, !userHash.isEmpty else {
            throw XboxAuthenticationError.missingValue("Xbox user-hash claim (DisplayClaims.xui[0].uhs)")
        }
        let xuid = (first["xid"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ""
        if requiresProfileClaims && xuid.isEmpty {
            throw XboxAuthenticationError.missingValue("Xbox profile XUID claim (DisplayClaims.xui[0].xid)")
        }
        return MSALXSTSResult(
            token: try string(object, "Token"),
            xboxUserID: xuid,
            userHash: userHash,
            gamertag: (first["mgt"] as? String) ?? (first["gtg"] as? String) ?? "Xbox Player"
        )
    }

    private func refreshMSALSession() async throws {
        guard let refreshToken = try SecureTokenStore.load(account: "xbl.msal.refresh-token") else {
            throw XboxAuthenticationError.missingValue("Microsoft Device Code refresh token")
        }
        let url = URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(formEncoded([
            "client_id": Constants.msalClientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": Constants.msalScopes
        ]).utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store, must-revalidate, no-cache", forHTTPHeaderField: "Cache-Control")
        let object = try jsonObject(await perform(request))
        let accessToken = try string(object, "access_token")
        let updatedRefresh = (object["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? refreshToken
        try SecureTokenStore.save(accessToken, account: "xbl.msal.access-token")
        try SecureTokenStore.save(updatedRefresh, account: "xbl.msal.refresh-token")

        let xboxUserToken = try await authenticateMicrosoftTokenWithXbox(accessToken)
        try SecureTokenStore.save(xboxUserToken, account: "xbl.msal.xbox-user-token")
        let web = try await requestMSALXSTS(userToken: xboxUserToken, relyingParty: "http://xboxlive.com")
        let home = try await requestMSALXSTS(userToken: xboxUserToken, relyingParty: "http://gssv.xboxlive.com/", requiresProfileClaims: false)
        let homeInfo = try await requestHomeStreamingToken(xstsToken: home.token)
        let cloudInfo = try? await requestCloudStreamingToken(xstsToken: home.token)
        let homeRegionData = try JSONEncoder().encode(homeInfo.regions)
        try SecureTokenStore.save(homeRegionData.base64EncodedString(), account: "xbl.msal.home-regions")
        let profile = XboxAccountProfile(id: web.xboxUserID, gamertag: web.gamertag, userHash: web.userHash)

        try SecureTokenStore.save(web.token, account: "xbl.msal.web-xsts")
        try SecureTokenStore.save(home.token, account: "xbl.msal.home-xsts")
        try SecureTokenStore.save(homeInfo.gsToken, account: "xbl.msal.home-gs-token")
        try SecureTokenStore.save(profile.gamertag, account: "xbl.profile-gamertag")
        try SecureTokenStore.save(profile.id, account: "xbl.profile-xuid")
        try SecureTokenStore.save(profile.userHash, account: "xbl.profile-user-hash")
        let tokenLifetime = min(cloudInfo?.durationInSeconds ?? homeInfo.durationInSeconds, homeInfo.durationInSeconds)
        cloudTokenExpiry = Date().addingTimeInterval(TimeInterval(tokenLifetime))
        try SecureTokenStore.save(String(cloudTokenExpiry!.timeIntervalSince1970), account: "xbl.cloud-token-expiry")
        if let cloudInfo {
            try SecureTokenStore.save(cloudInfo.gsToken, account: "xbl.cloud-stream-token")
            availableRegions = cloudInfo.regions
            try saveRegions(cloudInfo.regions)
        } else {
            try SecureTokenStore.delete(account: "xbl.cloud-stream-token")
            try SecureTokenStore.delete(account: "xbl.cloud-regions")
            availableRegions = []
            selectedRegionName = nil
        }
        account = profile
        statusMessage = cloudInfo == nil
            ? "Xbox account refreshed — Cloud Gaming unavailable; Remote Play credentials retained"
            : "Xbox account refreshed"
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
            let sisuAuthentication = try await beginSisuAuthentication(
                deviceToken: deviceToken,
                challenge: pkce
            )

            statusMessage = "Waiting for Microsoft sign-in…"
            let hintedURL = try microsoftSignInURL(sisuAuthentication.url, email: emailHint)
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
            let initialUserToken = try await exchangeAuthorizationCode(code, verifier: pkce.verifier)
            try SecureTokenStore.save(initialUserToken.accessToken, account: "xbl.user-access-token")
            try SecureTokenStore.save(initialUserToken.refreshToken, account: "xbl.user-refresh-token")

            // Match XStreaming's first silent-auth pass: after the OAuth code
            // exchange it refreshes the Microsoft user token, obtains a NEW
            // device token, then performs Sisu authorization without reusing
            // the Sisu-authentication SessionId.
            statusMessage = "Refreshing Microsoft authorization…"
            let userToken = try await refreshUserToken(initialUserToken.refreshToken)
            try SecureTokenStore.save(userToken.accessToken, account: "xbl.user-access-token")
            try SecureTokenStore.save(userToken.refreshToken, account: "xbl.user-refresh-token")

            statusMessage = "Refreshing Xbox device authorization…"
            let authorizedDeviceToken = try await requestDeviceToken(using: key)
            try SecureTokenStore.save(authorizedDeviceToken, account: "xbl.device-token")

            statusMessage = "Authorizing Xbox profile…"
            let sisu = try await requestSisuAuthorization(
                userAccessToken: userToken.accessToken,
                deviceToken: authorizedDeviceToken,
                using: key,
                sessionID: nil
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
            "xbl.msal.access-token", "xbl.msal.refresh-token", "xbl.msal.xbox-user-token",
            "xbl.msal.web-xsts", "xbl.msal.home-xsts", "xbl.msal.home-gs-token", "xbl.msal.home-regions",
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
        cloudAvailabilityMessage = nil
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
            let userHash = try? SecureTokenStore.load(account: "xbl.profile-user-hash")
        else { return }
        let msalRefresh = try? SecureTokenStore.load(account: "xbl.msal.refresh-token")
        let xalRefresh = try? SecureTokenStore.load(account: "xbl.user-refresh-token")
        let proofKey = try? SecureTokenStore.load(account: "xbl.proof-key")
        guard (msalRefresh?.isEmpty == false) || (xalRefresh?.isEmpty == false && proofKey?.isEmpty == false) else { return }
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
        if try SecureTokenStore.load(account: "xbl.msal.refresh-token") != nil {
            let cached = try SecureTokenStore.load(account: "xbl.cloud-stream-token")
            let fresh = (cloudTokenExpiry ?? .distantPast).timeIntervalSinceNow > 120
            if cached == nil || !fresh || availableRegions.isEmpty {
                try await refreshMSALSession()
            }
            if try SecureTokenStore.load(account: "xbl.cloud-stream-token") == nil || availableRegions.isEmpty {
                try await retryMSALCloudCredentials()
            }
            guard let token = try SecureTokenStore.load(account: "xbl.cloud-stream-token"),
                  let region = availableRegions.first(where: { $0.name == selectedRegionName })
                    ?? availableRegions.first(where: { $0.isDefault })
                    ?? availableRegions.first else {
                throw XboxAuthenticationError.missingValue("MSAL cloud streaming token or region")
            }
            return (token, region)
        }
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

    /// Re-request the Cloud Gaming offering independently from Microsoft sign-in.
    /// Regions are populated only from Xbox's authenticated offeringSettings response.
    func retryMSALCloudCredentials() async throws {
        guard !isAuthenticating else { return }
        guard let homeXSTS = try SecureTokenStore.load(account: "xbl.msal.home-xsts"),
              !homeXSTS.isEmpty else {
            throw XboxAuthenticationError.missingValue("Xbox home XSTS token; sign in again")
        }
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            let cloudInfo = try await requestCloudStreamingToken(xstsToken: homeXSTS)
            try SecureTokenStore.save(cloudInfo.gsToken, account: "xbl.cloud-stream-token")
            try saveRegions(cloudInfo.regions)
            availableRegions = cloudInfo.regions
            cloudTokenExpiry = Date().addingTimeInterval(TimeInterval(cloudInfo.durationInSeconds))
            try SecureTokenStore.save(String(cloudTokenExpiry!.timeIntervalSince1970), account: "xbl.cloud-token-expiry")
            if let selectedRegionName,
               !cloudInfo.regions.contains(where: { $0.name == selectedRegionName }) {
                self.selectedRegionName = nil
            }
            cloudAvailabilityMessage = nil
            statusMessage = "Xbox Cloud token ready — choose a server region"
        } catch {
            cloudAvailabilityMessage = error.localizedDescription
            statusMessage = "Signed in — Xbox Cloud Gaming offering unavailable"
            throw error
        }
    }

    /// Produces the distinct credentials required for Xbox Console Remote Play.
    /// The web token is used only for registered-console discovery; the xhome GS
    /// token is used only for /sessions/home signaling.
    func consoleRemotePlayCredentials() async throws -> XboxConsoleRemotePlayCredentials {
        if try SecureTokenStore.load(account: "xbl.msal.refresh-token") != nil {
            let cached = try SecureTokenStore.load(account: "xbl.msal.home-gs-token")
            let fresh = (cloudTokenExpiry ?? .distantPast).timeIntervalSinceNow > 120
            if cached == nil || !fresh { try await refreshMSALSession() }
            guard let web = try SecureTokenStore.load(account: "xbl.msal.web-xsts"),
                  let home = try SecureTokenStore.load(account: "xbl.msal.home-gs-token"),
                  let userHash = account?.userHash else {
                throw XboxAuthenticationError.missingValue("MSAL Xbox Remote Play credentials")
            }
            let homeRegions: [XboxCloudRegion]
            if let raw = try SecureTokenStore.load(account: "xbl.msal.home-regions"),
               let data = Data(base64Encoded: raw),
               let decoded = try? JSONDecoder().decode([XboxCloudRegion].self, from: data) {
                homeRegions = decoded
            } else {
                homeRegions = availableRegions
            }
            return XboxConsoleRemotePlayCredentials(
                webToken: web,
                homeGSToken: home,
                regions: homeRegions,
                userHash: userHash
            )
        }
        let cloudToken = try SecureTokenStore.load(account: "xbl.cloud-stream-token")
        let tokenIsFresh = (cloudTokenExpiry ?? .distantPast).timeIntervalSinceNow > 120
        if cloudToken == nil || !tokenIsFresh {
            try await refreshCloudCredentials()
        }

        guard let sisuUserToken = try SecureTokenStore.load(account: "xbl.sisu-user-token"),
              let userHash = account?.userHash,
              let rawKey = try SecureTokenStore.load(account: "xbl.proof-key"),
              let keyData = Data(base64Encoded: rawKey) else {
            throw XboxAuthenticationError.missingValue("Xbox Sisu credentials; sign in again")
        }
        let key = try XBLProofKey(rawRepresentation: keyData)
        guard let deviceToken = try SecureTokenStore.load(account: "xbl.device-token"),
              let titleToken = try SecureTokenStore.load(account: "xbl.sisu-title-token") else {
            throw XboxAuthenticationError.missingValue("Xbox device and title tokens; sign in again")
        }
        let webXSTS = try await requestConsoleXSTS(
            userToken: sisuUserToken,
            deviceToken: deviceToken,
            titleToken: titleToken,
            relyingParty: "http://xboxlive.com",
            using: key
        )
        let homeXSTS = try await requestConsoleXSTS(
            userToken: sisuUserToken,
            deviceToken: deviceToken,
            titleToken: titleToken,
            relyingParty: "http://gssv.xboxlive.com/",
            using: key
        )
        let homeInfo = try await requestHomeStreamingToken(xstsToken: homeXSTS)
        return XboxConsoleRemotePlayCredentials(
            webToken: webXSTS,
            homeGSToken: homeInfo.gsToken,
            regions: homeInfo.regions,
            userHash: userHash
        )
    }

    private func requestHomeStreamingToken(xstsToken: String) async throws -> CloudStreamingToken {
        let url = URL(string: "https://xhome.gssv-play-prod.xboxlive.com/v2/login/user")!
        let payload: [String: Any] = ["token": xstsToken, "offeringId": "xhome"]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store, must-revalidate, no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("XboxComBrowser", forHTTPHeaderField: "x-gssv-client")
        let object = try jsonObject(await perform(request))
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
        guard !regions.isEmpty else {
            throw XboxAuthenticationError.missingValue("available Xbox home-streaming regions")
        }
        return CloudStreamingToken(
            gsToken: try string(object, "gsToken"),
            regions: regions,
            durationInSeconds: object["durationInSeconds"] as? Int ?? 14_400
        )
    }

    /// Xbox Cloud's /connect endpoint expects the Passport console-transfer token,
    /// not the ordinary Microsoft account access token.
    func cloudTransferToken() async throws -> String {
        if let refreshToken = try SecureTokenStore.load(account: "xbl.msal.refresh-token") {
            let url = URL(string: "https://login.live.com/oauth20_token.srf")!
            let body = formEncoded([
                "client_id": Constants.msalClientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "scope": "service::http://Passport.NET/purpose::PURPOSE_XBOX_CLOUD_CONSOLE_TRANSFER_TOKEN"
            ])
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = Data(body.utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("no-store, must-revalidate, no-cache", forHTTPHeaderField: "Cache-Control")
            let object = try jsonObject(await perform(request))
            if let rotated = object["refresh_token"] as? String, !rotated.isEmpty {
                try SecureTokenStore.save(rotated, account: "xbl.msal.refresh-token")
            }
            return try string(object, "access_token")
        }
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

        // XStreaming's getDeviceTokenHack retries HTTP 400 up to 20 times.
        // Keep the same bounded retry behavior and never retry other statuses.
        for attempt in 1...20 {
            // XStreaming's native module uses UUID.randomUUID().toString().
            let deviceID = UUID().uuidString.lowercased()
            let serialNumber = UUID().uuidString.lowercased()
            // Match XStreaming's device-auth JSON byte-for-byte in field order.
            // Interpolated values are UUIDs and base64url JWK coordinates.
            let bodyString = "{\"Properties\":{\"AuthMethod\":\"ProofOfPossession\",\"Id\":\"{\(deviceID)}\",\"DeviceType\":\"Android\",\"SerialNumber\":\"{\(serialNumber)}\",\"Version\":\"15.0\",\"ProofKey\":{\"use\":\"sig\",\"alg\":\"ES256\",\"kty\":\"EC\",\"crv\":\"P-256\",\"x\":\"\(key.jwkX)\",\"y\":\"\(key.jwkY)\"}},\"RelyingParty\":\"http://auth.xboxlive.com\",\"TokenType\":\"JWT\"}"
            let body = Data(bodyString.utf8)

            do {
                let data = try await signedJSONBodyRequest(url: url, body: body, using: key, includeContentType: false)
                return try requiredString(data, path: ["Token"])
            } catch let error as XboxAuthenticationError {
                guard case .serverRejected(let statusCode, let details) = error else {
                    throw error
                }
                if statusCode == 400 {
                    continue
                }
                throw XboxAuthenticationError.serverRejected(
                    statusCode,
                    "device-auth attempt \(attempt)/20 | \(details)"
                )
            }
        }

        throw XboxAuthenticationError.invalidResponse
    }

    private func beginSisuAuthentication(
        deviceToken: String,
        challenge: PKCEChallenge
    ) async throws -> (url: URL, sessionID: String?) {
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
        let (data, response) = try await signedJSONRequestWithResponse(
            url: url,
            payload: payload,
            using: proofKey!,
            includeContentType: false
        )
        let object = try jsonObject(data)
        guard let nested = object["data"] as? [String: Any],
              let redirect = nested["MsaOauthRedirect"] as? String,
              let authorizationURL = URL(string: redirect) else {
            throw XboxAuthenticationError.missingValue("Microsoft authorization URL")
        }
        let sessionID = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "x-sessionid")
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

    /// Console discovery/home streaming uses the full Sisu token set in XSTS.
    /// Kept separate from the existing Cloud Gaming XSTS payload.
    private func requestConsoleXSTS(
        userToken: String,
        deviceToken: String,
        titleToken: String,
        relyingParty: String,
        using key: XBLProofKey
    ) async throws -> String {
        let url = URL(string: "https://xsts.auth.xboxlive.com/xsts/authorize")!
        let payload: [String: Any] = [
            "Properties": [
                "SandboxId": Constants.retailSandbox,
                "DeviceToken": deviceToken,
                "TitleToken": titleToken,
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
        } else {
            // XStreaming uses Axios 1.7.x and posts JSON.stringify(payload) as a
            // string. Axios' POST default is form-urlencoded unless overridden.
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
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
        let result = try await httpClient.execute(request)
        let data = result.data
        let response: URLResponse = result.response
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

struct XboxConsoleRemotePlayCredentials {
    let webToken: String
    let homeGSToken: String
    let regions: [XboxCloudRegion]
    let userHash: String
}

struct MicrosoftDeviceCode: Identifiable {
    let id = UUID()
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let verificationURLComplete: URL?
    let expiresAt: Date
    let interval: Int
    let message: String
}

private struct MSALXSTSResult {
    let token: String
    let xboxUserID: String
    let userHash: String
    let gamertag: String
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
