// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

@MainActor
final class OneClient: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let origin = URL(string: "https://one.hyrovi.com")!

    private let clientId = "hyrovi-browser-ios"
    private let redirectURI = "hyrovi-browser://auth/callback"
    private let scope = "profile runtime"
    private var webAuthenticationSession: ASWebAuthenticationSession?

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
        guard KeychainStore.token() != nil else { return nil }

        do {
            let session: OneSession = try await authorized(path: "/api/runtime/v1/session")
            guard session.authenticated else {
                KeychainStore.deleteToken()
                return nil
            }
            return session
        } catch {
            return nil
        }
    }

    func signIn() async throws -> OneSession {
        let verifier = try randomBase64URL(byteCount: 48)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = try randomBase64URL(byteCount: 32)

        var components = URLComponents(
            url: Self.origin.appendingPathComponent("/identity/authorize"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        guard let authorizeURL = components.url else {
            throw OneClientError.invalidURL
        }

        let callback = try await authenticate(url: authorizeURL)
        guard callback.scheme == "hyrovi-browser",
              callback.host == "auth",
              callback.path == "/callback" else {
            throw OneClientError.invalidCallback
        }

        let callbackComponents = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        let values = Dictionary(
            uniqueKeysWithValues: (callbackComponents?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        guard values["state"] == state,
              let code = values["code"],
              code.count >= 43 else {
            throw OneClientError.invalidCallback
        }

        let token: TokenResponse = try await request(
            path: "/api/identity/token",
            method: "POST",
            authorized: false,
            body: [
                "grant_type": "authorization_code",
                "code": code,
                "client_id": clientId,
                "redirect_uri": redirectURI,
                "code_verifier": verifier
            ]
        )

        guard token.tokenType.lowercased() == "bearer",
              token.accessToken.hasPrefix("hyrovi_identity_") else {
            throw OneClientError.invalidToken
        }

        try KeychainStore.saveToken(token.accessToken)
        guard let session = await restoreSession() else {
            KeychainStore.deleteToken()
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

    private func randomBase64URL(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let result = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, buffer.baseAddress!)
        }
        guard result == errSecSuccess else {
            throw OneClientError.randomUnavailable
        }
        return base64URL(Data(bytes))
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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
