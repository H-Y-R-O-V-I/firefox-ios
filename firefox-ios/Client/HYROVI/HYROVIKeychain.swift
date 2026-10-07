// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import Security

enum KeychainStore {
    private static let service = "com.hyrovi.browser.ios"
    private static let tokenAccount = "hyrovi-one-access-token"
    private static let privateSealIdentityPrefix = "hyrovi-private-age-identity:"

    static func saveToken(_ token: String) throws {
        try save(
            token,
            account: tokenAccount,
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
    }

    static func token() -> String? {
        value(account: tokenAccount)
    }

    static func deleteToken() {
        delete(account: tokenAccount)
    }

    static func savePrivateSealIdentity(_ identity: String, accountUsername: String) throws {
        try save(
            identity,
            account: privateSealIdentityPrefix + accountUsername,
            accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
    }

    static func privateSealIdentity(accountUsername: String) -> String? {
        value(account: privateSealIdentityPrefix + accountUsername)
    }

    private static func save(
        _ value: String,
        account: String,
        accessible: CFString
    ) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = accessible

        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private static func value(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
