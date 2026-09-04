// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Nam Jung Hyun (rkttu)
//
// This file is part of MacSandbox, which is dual-licensed:
//   (1) under the GNU Affero General Public License v3.0 or later (see LICENSE), or
//   (2) under a commercial license (see COMMERCIAL-LICENSE.md).
// You may use this file under the terms of either license.
//
// MacSandbox is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.

import Foundation
import Security

enum BaselineCredentialStore {
    private static let service = "com.yourtablecloth.macSandbox.baseline-rdp"

    enum CredentialError: LocalizedError {
        case randomGenerationFailed
        case keychain(OSStatus)
        case missing

        var errorDescription: String? {
            switch self {
            case .randomGenerationFailed:
                return "Could not generate a baseline credential."
            case .keychain:
                return "Could not access the baseline credential in Keychain."
            case .missing:
                return "The baseline credential is missing. Rebuild the baseline."
            }
        }
    }

    static func generatePassword() throws -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".utf8)
        var random = [UInt8](repeating: 0, count: 29)
        var result: [UInt8] = []
        result.reserveCapacity(random.count)

        while result.count < random.count {
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
                throw CredentialError.randomGenerationFailed
            }
            for byte in random where byte < 248 {
                result.append(alphabet[Int(byte) % alphabet.count])
                if result.count == random.count { break }
            }
        }
        return "Aa1" + String(decoding: result, as: UTF8.self)
    }

    static func save(password: String, id: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: id,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: Data(password.utf8),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
    }

    static func password(for id: String) throws -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: id,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { throw CredentialError.missing }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
        guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            throw CredentialError.missing
        }
        return password
    }

    static func delete(id: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: id,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
