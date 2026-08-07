import Foundation

/// The one question the keyboard may ask about money: "is Ara unlocked?" —
/// answered from the App Group boolean the app mirrors after StoreKit
/// resolves entitlements. The keyboard never links StoreKit and never shows a
/// price (App Review 4.4); the app owns purchase, restore, and the mirror.
enum StoreGate {
    static let productID = "com.silpho.ara.lifetime"

    /// Read by both processes. Written only by the app's StoreService.
    static var isUnlocked: Bool {
        Relay.defaults?.bool(forKey: Relay.Key.entitled) ?? false
    }

    static func mirror(unlocked: Bool) {
        Relay.defaults?.set(unlocked, forKey: Relay.Key.entitled)
    }
}
