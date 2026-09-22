import Foundation
import Security

/// Usage polling never opens macOS authorization dialogs.
enum BackgroundKeychain {
    private static let interactionLock = NSRecursiveLock()

    // Claude uses the legacy login Keychain. Per-query authentication flags
    // alone are insufficient there. Scope its process-wide UI policy to this
    // synchronous call and serialize all AgentBar Keychain access around it.
    // Restore the previous policy before releasing the lock, including on error.
    static func withInteraction<T>(_ allowed: Bool, _ operation: () throws -> T) throws -> T {
        interactionLock.lock(); defer { interactionLock.unlock() }
        var previous = DarwinBoolean(false)
        let readStatus = SecKeychainGetUserInteractionAllowed(&previous)
        guard readStatus == errSecSuccess else { throw ReadError.failed(readStatus) }
        let setStatus = SecKeychainSetUserInteractionAllowed(allowed)
        guard setStatus == errSecSuccess else { throw ReadError.failed(setStatus) }
        defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return try operation()
    }
    enum ReadError: LocalizedError {
        case authorizationRequired
        case failed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .authorizationRequired:
                return "The saved credential is unavailable. Reconnect this account to read its usage."
            case .failed(let status):
                return "Could not read the Claude credential (Keychain status \(status))."
            }
        }
    }

    static func query(service: String, account: String?, secret: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        if let account { query[kSecAttrAccount as String] = account }
        query[(secret ? kSecReturnData : kSecReturnAttributes) as String] = true
        return query
    }

    static func read(service: String, account: String?) throws -> Data? {
        try withInteraction(false) { try read(query: query(service: service, account: account, secret: true)) }
    }

    /// Only called while completing an explicit account connection. Once copied
    /// into that account's private file, polling needs no Keychain authorization.
    static func readForLogin(service: String, account: String?) throws -> Data? {
        var query = query(service: service, account: account, secret: true)
        query.removeValue(forKey: kSecUseAuthenticationUI as String)
        return try withInteraction(true) { try read(query: query) }
    }

    private static func read(query: [String: Any]) throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            throw ReadError.authorizationRequired
        default: throw ReadError.failed(status)
        }
    }

    static func contains(service: String) -> Bool {
        (try? withInteraction(false) {
            SecItemCopyMatching(query(service: service, account: nil, secret: false) as CFDictionary, nil)
        }) == errSecSuccess
    }
}
