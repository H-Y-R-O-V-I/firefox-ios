// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import AuthenticationServices
import Foundation
import UIKit

@MainActor
final class OneClient: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let origin = URL(string: "https://one.hyrovi.com")!

    private var webAuthenticationSession: ASWebAuthenticationSession?
    private var accountUsername: String?

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        return windows.first(where: { $0.isKeyWindow }) ?? windows.first ?? ASPresentationAnchor()
    }

    func restoreSession() async -> OneSession? {
        guard let token = KeychainStore.token() else { return nil }
        guard HYROVIEngineCore.shared.setAccessToken(token) else {
            KeychainStore.deleteToken()
            return nil
        }

        do {
            let session: OneSession = try await authorized(path: "/api/runtime/v1/session")
            guard session.authenticated else {
                KeychainStore.deleteToken()
                return nil
            }
            accountUsername = session.user
            // Registration is best-effort for session restoration. The private
            // viewer retries it when a private Shared Session is actually opened.
            _ = try? await ensurePrivateSealIdentityRegistered()
            return session
        } catch {
            return nil
        }
    }

    func signIn() async throws -> OneSession {
        let attempt = try HYROVIEngineCore.shared.beginLogin()
        guard let authorizeURL = URL(string: attempt.authorizeURL) else {
            throw OneClientError.invalidURL
        }

        let callback = try await authenticate(url: authorizeURL)
        let exchange = try HYROVIEngineCore.shared.completeLogin(callbackURL: callback.absoluteString)

        let token: TokenResponse = try await request(
            path: "/api/identity/token",
            method: "POST",
            authorized: false,
            body: [
                "grant_type": exchange.grantType,
                "code": exchange.code,
                "client_id": exchange.clientId,
                "redirect_uri": exchange.redirectUri,
                "code_verifier": exchange.codeVerifier
            ]
        )

        guard token.tokenType.lowercased() == "bearer",
              token.accessToken.hasPrefix("hyrovi_identity_"),
              HYROVIEngineCore.shared.setAccessToken(token.accessToken) else {
            throw OneClientError.invalidToken
        }

        try KeychainStore.saveToken(token.accessToken)
        guard let session = await restoreSession() else {
            KeychainStore.deleteToken()
            HYROVIEngineCore.shared.signOut()
            throw OneClientError.invalidToken
        }
        return session
    }

    func signOut() async {
        if KeychainStore.token() != nil {
            _ = try? await rawRequest(
                path: "/api/identity/revoke",
                method: "POST",
                authorized: true
            )
        }
        KeychainStore.deleteToken()
        accountUsername = nil
        HYROVIEngineCore.shared.signOut()
    }

    func listRemoteTabs() async throws -> [RemoteStream] {
        let response: RemoteStreamList = try await authorized(
            path: "/api/runtime/v1/browser/remote-tabs"
        )
        return response.streams
    }

    func remoteTab(id: String, since revision: Int) async throws -> RemoteStreamState {
        try await authorized(
            path: "/api/runtime/v1/browser/remote-tabs/\(id)?since=\(max(0, revision))"
        )
    }

    func sendRemoteAction(streamId: String, action: [String: Any]) async throws {
        let _: QueuedActionResponse = try await request(
            path: "/api/runtime/v1/browser/remote-tabs/\(streamId)/actions",
            method: "POST",
            authorized: true,
            body: ["action": action]
        )
    }

    func sendPrivateRemoteAction(
        streamId: String,
        sealedAction: SealedRelayPayload
    ) async throws {
        let data = try JSONEncoder().encode(sealedAction)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OneClientError.invalidResponse
        }
        let _: QueuedActionResponse = try await request(
            path: "/api/runtime/v1/browser/remote-tabs/\(streamId)/actions",
            method: "POST",
            authorized: true,
            body: ["sealedAction": value]
        )
    }

    func ensurePrivateSealIdentityRegistered() async throws
        -> (identity: String, key: HYROVISealKey) {
        guard let accountUsername, !accountUsername.isEmpty else {
            throw OneClientError.notAuthenticated
        }

        let pair: (identity: String, key: HYROVISealKey)
        if let identity = KeychainStore.privateSealIdentity(accountUsername: accountUsername) {
            pair = (
                identity,
                try HYROVIEngineCore.shared.describeSealIdentity(identity)
            )
        } else {
            let generated = try HYROVIEngineCore.shared.generateSealIdentity()
            try KeychainStore.savePrivateSealIdentity(
                generated.identity,
                accountUsername: accountUsername
            )
            pair = (generated.identity, generated.key)
        }

        let response: BrowserClientKeyRegistrationResponse = try await request(
            path: "/api/runtime/v1/browser/client-key",
            method: "PUT",
            authorized: true,
            body: [
                "keyId": pair.key.keyId,
                "recipient": pair.key.recipient,
                "displayName": UIDevice.current.name
            ]
        )
        guard response.ok else {
            throw OneClientError.invalidResponse
        }
        return pair
    }

    func browserSync() async throws -> BrowserSyncState {
        try await authorized(path: "/api/runtime/v1/browser/sync")
    }

    private func authenticate(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: "hyrovi-browser"
            ) { [weak self] callback, error in
                self?.webAuthenticationSession = nil

                if let error {
                    continuation.resume(throwing: error)
                } else if let callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(throwing: OneClientError.invalidCallback)
                }
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.webAuthenticationSession = session

            guard session.start() else {
                self.webAuthenticationSession = nil
                continuation.resume(throwing: OneClientError.authenticationUnavailable)
                return
            }
        }
    }

    private func authorized<T: Decodable>(path: String) async throws -> T {
        try await request(path: path, method: "GET", authorized: true, body: nil)
    }

    private func request<T: Decodable>(
        path: String,
        method: String,
        authorized: Bool,
        body: [String: Any]?
    ) async throws -> T {
        let (data, response) = try await rawRequest(
            path: path,
            method: method,
            authorized: authorized,
            body: body
        )

        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 {
                KeychainStore.deleteToken()
            }
            throw OneClientError.http(response.statusCode)
        }

        return try decoder.decode(T.self, from: data)
    }

    private func rawRequest(
        path: String,
        method: String,
        authorized: Bool,
        body: [String: Any]? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: path, relativeTo: Self.origin)?.absoluteURL else {
            throw OneClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if authorized {
            guard let token = KeychainStore.token() else {
                throw OneClientError.notAuthenticated
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OneClientError.invalidResponse
        }
        return (data, http)
    }
}

enum OneClientError: LocalizedError {
    case invalidURL
    case invalidResponse
    case invalidCallback
    case invalidToken
    case notAuthenticated
    case authenticationUnavailable
    case randomUnavailable
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Ungültige HYROVI-One-Adresse."
        case .invalidResponse:
            return "Ungültige Antwort von HYROVI One."
        case .invalidCallback:
            return "Die Anmeldung konnte nicht bestätigt werden."
        case .invalidToken:
            return "HYROVI One hat keinen gültigen Browser-Token geliefert."
        case .notAuthenticated:
            return "Nicht mit HYROVI One angemeldet."
        case .authenticationUnavailable:
            return "Die One-Anmeldung konnte nicht geöffnet werden."
        case .randomUnavailable:
            return "Sicherer Zufall konnte nicht erzeugt werden."
        case .http(let status):
            return "HYROVI One HTTP \(status)."
        }
    }
}
