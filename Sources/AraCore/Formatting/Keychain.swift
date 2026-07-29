import Foundation
import Security

/// Why a keychain write can fail. Deliberately its own type: `Keychain` is not
/// a formatter, and reporting a denied Allow/Deny prompt as
/// `FormatterError.transportFailure` would print "transport failure: keychain
/// add failed (OSStatus -25308)" — a sentence about the network that is false.
public enum KeychainError: Error, Sendable, CustomStringConvertible, LocalizedError {
    case addFailed(OSStatus)
    case updateFailed(OSStatus)

    /// Carries the `OSStatus` and never the value, so a message that reaches a
    /// log or a bug report cannot carry the credential.
    public var description: String {
        switch self {
        case .addFailed(let status): return "keychain add failed (OSStatus \(status))"
        case .updateFailed(let status): return "keychain update failed (OSStatus \(status))"
        }
    }

    /// `LocalizedError` as well as `CustomStringConvertible`, because they feed
    /// different renderers and callers reach for both. Without this,
    /// `localizedDescription` — which is what most error-reporting code prints —
    /// yields "The operation couldn't be completed. (AraCore.KeychainError
    /// error 0.)" and the `OSStatus` that would actually explain the failure is
    /// lost.
    public var errorDescription: String? { description }
}

/// Generic-password storage for the cloud API key.
///
/// The key lives here and nowhere else: `config.json` is a plain file in the
/// user's home directory that this project's own documentation invites people
/// to paste into issues, and this repository is headed for public release. A
/// credential in it would be one screenshot away from being someone else's.
///
/// ## Which keychain
///
/// No `kSecUseDataProtectionKeychain`, so these items land in the **legacy file
/// keychain** (`login.keychain-db`) rather than the data-protection keychain.
/// That is a constraint rather than a preference: the data-protection keychain
/// needs a `keychain-access-groups` entitlement, which needs a signed,
/// provisioned binary, and this ships as an unsigned SwiftPM executable to
/// `/usr/local/bin`. Two consequences are worth knowing before reading the code
/// below. `kSecAttrAccessible` is largely advisory on the legacy keychain —
/// access is governed by the item's ACL instead — and that ACL trusts the
/// creating binary *by identity*, which an unsigned binary does not stably
/// have. In practice every rebuild produces a binary the ACL does not
/// recognise, so the user is prompted again.
public enum Keychain {
    private static let service = "com.digimata.ara"

    /// The stored password for `account`, or `nil` if there is none.
    ///
    /// **This call can block its thread for an unbounded time, and callers must
    /// keep it off the cooperative pool.** A missing item is cheap — it returns
    /// `errSecItemNotFound` immediately — but a *locked* keychain, or an item
    /// whose ACL does not trust this binary, makes `SecItemCopyMatching` put an
    /// unlock or Allow/Deny dialog in front of the user and block until they
    /// answer it. That is human-paced, and neither state is exotic here: an
    /// unsigned binary has no stable identity for the ACL to trust, so a
    /// rebuild re-prompts (see the note on the legacy keychain above).
    ///
    /// `FormatterChain.withDeadline` abandons a slow formatter without freeing
    /// its thread, so a blocking read reached from the dictation path holds a
    /// pool thread for as long as the dialog sits unanswered — the stall that
    /// comment measures at 9.16s, here with no upper bound at all. Read once at
    /// startup, off the pool, and hand `CloudFormatter` the cached value.
    ///
    /// Non-throwing because every caller's response to a failed read is the
    /// same: behave as if no key were configured.
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
    /// Blocks on a prompt under the same conditions as `readPassword`. A write
    /// happens during setup rather than during dictation, so it costs nobody a
    /// pool thread, but it is the same mechanism.
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
        guard added == errSecDuplicateItem else { throw KeychainError.addFailed(added) }

        // Carries `kSecAttrAccessible` as well as the data, so an item created
        // by some other route converges on the attributes this code intends
        // rather than keeping whatever it was born with forever.
        let updated = SecItemUpdate(identity as CFDictionary, [
            kSecValueData as String: secret,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ] as CFDictionary)
        guard updated == errSecSuccess else { throw KeychainError.updateFailed(updated) }
    }
}
