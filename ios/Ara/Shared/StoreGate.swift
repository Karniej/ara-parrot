import Foundation

/// The one question the keyboard may ask about money: "is Ara unlocked?" —
/// answered from the App Group boolean the app mirrors after StoreKit
/// resolves entitlements. The keyboard never links StoreKit and never shows a
/// price (App Review 4.4); the app owns purchase, restore, and the mirror.
enum StoreGate {
    static let productID = "com.silpho.ara.lifetime"

    /// Read by both processes. Written only by the app's StoreService.
    static var isUnlocked: Bool {
        #if DEBUG
        if debugUnlocked { return true }
        #endif
        return Relay.defaults?.bool(forKey: Relay.Key.entitled) ?? false
    }

    static func mirror(unlocked: Bool) {
        Relay.defaults?.set(unlocked, forKey: Relay.Key.entitled)
    }

    #if DEBUG
    /// A developer override, so testing dictation on a device does not require
    /// re-buying after every reinstall. Deliberately a *separate* key OR'd in
    /// rather than a write to `entitled`: `refreshEntitlement()` rewrites the
    /// real mirror from `currentEntitlements` on every launch and would erase
    /// anything stored there, and keeping them apart means the paywall path
    /// stays exercisable — turn this off and the real gate is back, untouched.
    ///
    /// Compiled out of Release entirely; a shipped build has no way to set it.
    static var debugUnlocked: Bool {
        get { Relay.defaults?.bool(forKey: Relay.Key.debugUnlocked) ?? false }
        set { Relay.defaults?.set(newValue, forKey: Relay.Key.debugUnlocked) }
    }
    #endif
}
