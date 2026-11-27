import Foundation
import Security

/// Where Modlight keeps secrets: the RunPod and Venice keys, the Hugging Face token, the local gateway key.
///
/// Only the macOS Keychain, never a file or `UserDefaults`, and never logged. A value is written,
/// read back when needed, and replaced or deleted; there is deliberately no way to list values.
public struct KeychainStore: Sendable {
    public struct Item: Sendable, Hashable {
        public let account: String
        public init(_ account: String) { self.account = account }

        public static let runpodAPIKey = Item("runpod-api-key")
        public static let huggingFaceToken = Item("huggingface-token")
        /// The key for Venice.ai's API (an Inference key is enough).
        public static let veniceAPIKey = Item("venice-api-key")
        /// The key local agents use for Modlight's gateway.
        public static let gatewayKey = Item("gateway-key")
        /// The key between Modlight and one model's pod (vLLM and the watchdog).
        public static func podKey(_ model: UUID) -> Item { Item("pod-key-\(model.uuidString)") }
    }

    public struct Failure: Error, Sendable, Equatable, CustomStringConvertible {
        public var status: OSStatus
        public var description: String {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }

    /// Keychain service name. The app passes its bundle identifier; tests pass a throwaway one.
    public let service: String

    public init(service: String = "app.modlight") {
        self.service = service
    }

    public func read(_ item: Item) throws -> String? {
        var query = baseQuery(item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        default:
            throw Failure(status: status)
        }
    }

    /// Stores `value`, replacing what was there. Surrounding whitespace is dropped: a key pasted
    /// with a trailing newline would otherwise fail as "invalid" with no visible reason.
    public func write(_ value: String, for item: Item) throws {
        let data = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let update = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(baseQuery(item) as CFDictionary, update)
        if status == errSecItemNotFound {
            var add = baseQuery(item)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure(status: added) }
        } else if status != errSecSuccess {
            throw Failure(status: status)
        }
    }

    public func delete(_ item: Item) throws {
        let status = SecItemDelete(baseQuery(item) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    public func contains(_ item: Item) -> Bool {
        var query = baseQuery(item)
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private func baseQuery(_ item: Item) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.account,
        ]
    }
}
