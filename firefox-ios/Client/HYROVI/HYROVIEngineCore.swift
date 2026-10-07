// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import HyroviEngine

struct HYROVIEnginePKCEAttempt: Decodable {
    let verifier: String
    let state: String
    let authorizeURL: String
}

struct HYROVIEngineTokenExchange: Decodable {
    let grantType: String
    let code: String
    let clientId: String
    let redirectUri: String
    let codeVerifier: String
}

private final class HYROVIRuntimeHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        hyrovi_runtime_free(pointer)
    }
}

@MainActor
final class HYROVIEngineCore {
    static let shared = HYROVIEngineCore()

    private let runtimeHandle: HYROVIRuntimeHandle
    private var runtime: OpaquePointer { runtimeHandle.pointer }
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private let encoder = JSONEncoder()

    private init() {
        guard let runtime = hyrovi_runtime_new(true) else {
            fatalError("HYROVI Engine runtime konnte nicht erstellt werden.")
        }
        self.runtimeHandle = HYROVIRuntimeHandle(pointer: runtime)
    }

    func beginLogin() throws -> HYROVIEnginePKCEAttempt {
        try decode(hyrovi_runtime_begin_login(runtime), as: HYROVIEnginePKCEAttempt.self)
    }

    func completeLogin(callbackURL: String) throws -> HYROVIEngineTokenExchange {
        try callbackURL.withCString { callback in
            try decode(
                hyrovi_runtime_complete_login(runtime, callback),
                as: HYROVIEngineTokenExchange.self
            )
        }
    }

    @discardableResult
    func setAccessToken(_ token: String) -> Bool {
        token.withCString { hyrovi_runtime_set_access_token(runtime, $0) }
    }

    func signOut() {
        _ = hyrovi_runtime_sign_out(runtime)
    }

    func generateSealIdentity() throws -> HYROVISealIdentityBundle {
        try decode(hyrovi_seal_identity_generate(), as: HYROVISealIdentityBundle.self)
    }

    func describeSealIdentity(_ identity: String) throws -> HYROVISealKey {
        try identity.withCString {
            try decode(hyrovi_seal_identity_describe($0), as: HYROVISealKey.self)
        }
    }

    func openRelayKey(identity: String, sealedKey: SealedRelayKey) throws -> String {
        let sealedData = try encoder.encode(sealedKey)
        guard let sealedJSON = String(data: sealedData, encoding: .utf8) else {
            throw HYROVIEngineCoreError.invalidBridgeResponse
        }
        return try identity.withCString { identityCString in
            try sealedJSON.withCString { sealedCString in
                try decodeString(hyrovi_relay_key_open(identityCString, sealedCString))
            }
        }
    }

    func openRelaySnapshot(relayKey: String, sealed: SealedRelayPayload) throws -> RemoteSnapshot {
        let sealedData = try encoder.encode(sealed)
        guard let sealedJSON = String(data: sealedData, encoding: .utf8) else {
            throw HYROVIEngineCoreError.invalidBridgeResponse
        }
        return try relayKey.withCString { keyCString in
            try sealedJSON.withCString { sealedCString in
                try decode(
                    hyrovi_relay_snapshot_open(keyCString, sealedCString),
                    as: RemoteSnapshot.self
                )
            }
        }
    }

    func sealRelayAction(
        relayKey: String,
        counter: UInt64,
        action: [String: Any]
    ) throws -> SealedRelayPayload {
        let data = try JSONSerialization.data(withJSONObject: action)
        guard let json = String(data: data, encoding: .utf8) else {
            throw HYROVIEngineCoreError.invalidBridgeResponse
        }
        return try relayKey.withCString { keyCString in
            try json.withCString { actionCString in
                try decode(
                    hyrovi_relay_action_seal(keyCString, counter, actionCString),
                    as: SealedRelayPayload.self
                )
            }
        }
    }

    private func decode<T: Decodable>(
        _ raw: UnsafeMutablePointer<CChar>?,
        as type: T.Type
    ) throws -> T {
        let json = try decodeString(raw)
        guard let data = json.data(using: .utf8) else {
            throw HYROVIEngineCoreError.invalidBridgeResponse
        }
        return try decoder.decode(type, from: data)
    }

    private func decodeString(_ raw: UnsafeMutablePointer<CChar>?) throws -> String {
        guard let raw else {
            throw HYROVIEngineCoreError.invalidBridgeResponse
        }
        defer { hyrovi_string_free(raw) }
        return String(cString: raw)
    }
}

enum HYROVIEngineCoreError: LocalizedError {
    case invalidBridgeResponse

    var errorDescription: String? {
        "HYROVI Engine hat eine ungültige Runtime-Antwort geliefert."
    }
}
