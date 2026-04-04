//
//  BedrockModerationDefaults.swift
//  TheTubHarness
//
//  Fixed (non-user-configurable) Bedrock moderation defaults.
//  Bearer token is read from Keychain only.
//

import Foundation
import Security

enum BedrockModerationDefaults {
    // Non-configurable runtime defaults.
    static let region = "us-east-1"
    static let guardrailIdentifier = "tubmoderation"
    static let guardrailVersion = "DRAFT"
    static let outputScope: String? = "INTERVENTIONS"
    static let endpointOverride: String? = nil
    static let timeoutSeconds: TimeInterval = 1.0

    static func bearerTokenFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }
        return token
    }

    // Keep stable so deploy tooling can provision this once.
    static let keychainService = "com.stagedevices.tubharness.bedrock"
    static let keychainAccount = "moderation_api_token"
}
