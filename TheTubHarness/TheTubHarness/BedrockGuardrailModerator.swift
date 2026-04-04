//
//  BedrockGuardrailModerator.swift
//  TheTubHarness
//
//  Optional Bedrock Guardrails moderation path for speech text.
//  Uses fixed app defaults + Keychain token, then falls back to local moderation
//  if Bedrock is unavailable.
//

import Foundation

actor BedrockGuardrailModerator {
    static let shared = BedrockGuardrailModerator()

    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var cache: [String: String] = [:]
    private var cacheOrder: [String] = []
    private let maxCacheEntries = 256

    private var activeConfigKey: String?
    private var consecutiveFailures: Int = 0
    private var cooldownUntil: Date?

    init(session: URLSession = .shared) {
        self.session = session
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    func moderate(line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        guard let config = Configuration.loadPersisted() else { return nil }

        let configKey = config.cacheKey
        if activeConfigKey != configKey {
            activeConfigKey = configKey
            cache.removeAll(keepingCapacity: true)
            cacheOrder.removeAll(keepingCapacity: true)
            consecutiveFailures = 0
            cooldownUntil = nil
        }

        if let until = cooldownUntil, Date() < until {
            return nil
        }

        if let cached = cache[trimmed] {
            return cached
        }

        do {
            let moderated = try await requestModeration(for: trimmed, config: config)
            consecutiveFailures = 0
            cooldownUntil = nil
            cacheValue(moderated, for: trimmed)
            return moderated
        } catch {
            consecutiveFailures += 1
            if consecutiveFailures >= 3 {
                cooldownUntil = Date().addingTimeInterval(8)
            }
            return nil
        }
    }

    private func requestModeration(for line: String, config: Configuration) async throws -> String {
        guard let url = config.endpointURL else { throw ModerationError.invalidConfiguration }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.bearerToken)", forHTTPHeaderField: "Authorization")

        let body = ApplyGuardrailRequest(
            content: [ApplyGuardrailRequest.ContentBlock(text: .init(text: line))],
            outputScope: config.outputScope,
            source: "INPUT"
        )
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ModerationError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw ModerationError.http(http.statusCode) }

        let decoded = try decoder.decode(ApplyGuardrailResponse.self, from: data)
        if decoded.action == "GUARDRAIL_INTERVENED" {
            if let replacement = decoded.outputs?.compactMap(\.text).first,
               !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return replacement
            }
            return StageTextModeration.redactionToken
        }
        return line
    }

    private func cacheValue(_ value: String, for key: String) {
        if cache[key] == nil {
            cacheOrder.append(key)
        }
        cache[key] = value

        if cacheOrder.count > maxCacheEntries, let evicted = cacheOrder.first {
            cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }
}

private extension BedrockGuardrailModerator {
    struct Configuration {
        let region: String
        let guardrailIdentifier: String
        let guardrailVersion: String
        let bearerToken: String
        let outputScope: String?
        let endpointOverride: String?
        let timeoutSeconds: TimeInterval

        var cacheKey: String {
            "\(region)|\(guardrailIdentifier)|\(guardrailVersion)|\(outputScope ?? "INTERVENTIONS")|\(endpointOverride ?? "")"
        }

        var endpointURL: URL? {
            let base = endpointOverride ?? "https://bedrock-runtime.\(region).amazonaws.com"
            guard var components = URLComponents(string: base) else { return nil }
            let encodedId = guardrailIdentifier.addingPercentEncoding(withAllowedCharacters: .bedrockPathParameterAllowed)
                ?? guardrailIdentifier
            let encodedVersion = guardrailVersion.addingPercentEncoding(withAllowedCharacters: .bedrockPathParameterAllowed)
                ?? guardrailVersion
            components.path = "/guardrail/\(encodedId)/version/\(encodedVersion)/apply"
            return components.url
        }

        static func loadPersisted() -> Configuration? {
            guard let token = BedrockModerationDefaults.bearerTokenFromKeychain() else { return nil }

            return Configuration(
                region: BedrockModerationDefaults.region,
                guardrailIdentifier: BedrockModerationDefaults.guardrailIdentifier,
                guardrailVersion: BedrockModerationDefaults.guardrailVersion,
                bearerToken: token,
                outputScope: BedrockModerationDefaults.outputScope,
                endpointOverride: BedrockModerationDefaults.endpointOverride,
                timeoutSeconds: BedrockModerationDefaults.timeoutSeconds
            )
        }
    }

    struct ApplyGuardrailRequest: Encodable {
        struct ContentBlock: Encodable {
            struct TextBlock: Encodable {
                let text: String
            }

            let text: TextBlock
        }

        let content: [ContentBlock]
        let outputScope: String?
        let source: String
    }

    struct ApplyGuardrailResponse: Decodable {
        struct OutputBlock: Decodable {
            let text: String?
        }

        let action: String?
        let outputs: [OutputBlock]?
    }

    enum ModerationError: Error {
        case invalidConfiguration
        case invalidResponse
        case http(Int)
    }
}

private extension CharacterSet {
    static let bedrockPathParameterAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return allowed
    }()
}
