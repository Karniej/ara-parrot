import Foundation
import Security

/// Generic-password storage for the cloud API key.
///
/// The key lives here and nowhere else: `config.json` is a plain file in the
/// user's home directory that this project's own documentation invites people
/// to paste into issues, and this repository is headed for public release. A
/// credential in it would be one screenshot away from being someone else's.
public enum Keychain {
    private static let service = "com.digimata.ara"

    /// The stored password for `account`, or `nil` if there is none.
    ///
    /// Deliberately non-throwing. Every caller's response to a failed read is
    /// the same — behave as if no key were configured — and a keychain that is
    /// locked, empty, or missing the item is a normal state on a machine where
    /// the user has simply not opted in to cloud formatting.
    public static func readPassword(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    /// Stores `value` for `account`, replacing any existing password.
    ///
    /// Adds first and updates only on `errSecDuplicateItem`, rather than
    /// deleting and then adding. The delete-then-add shape reads more simply
    /// but has a destructive failure mode: if the add fails — a locked
    /// keychain, a denied prompt, an interrupted process — the user's existing
    /// key is already gone and cloud formatting silently stops working, with
    /// nothing left on disk to recover it from. Here a failed write leaves the
    /// previous key exactly where it was.
    ///
    /// The thrown detail carries the `OSStatus` and never the value, so a
    /// message that reaches a log or a bug report cannot carry the credential.
    public static func writePassword(_ value: String, account: String) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let secret = Data(value.utf8)

        var add = identity
        add[kSecValueData as String] = secret
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let added = SecItemAdd(add as CFDictionary, nil)
        if added == errSecSuccess { return }
        guard added == errSecDuplicateItem else {
            throw FormatterError.transportFailure("keychain add failed (OSStatus \(added))")
        }

        let updated = SecItemUpdate(
            identity as CFDictionary,
            [kSecValueData as String: secret] as CFDictionary)
        guard updated == errSecSuccess else {
            throw FormatterError.transportFailure("keychain update failed (OSStatus \(updated))")
        }
    }
}
