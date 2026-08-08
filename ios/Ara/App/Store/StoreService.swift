import Foundation
import StoreKit

/// StoreKit 2, directly — no RevenueCat, no SDK, no account. The privacy
/// nutrition label stays literally empty only if nothing phones anywhere;
/// Apple's own rails give account-free restore via
/// `Transaction.currentEntitlements`. The result is mirrored to the App
/// Group boolean the keyboard reads (`StoreGate`) — the keyboard never
/// links StoreKit and never sees a price.
@MainActor
final class StoreService: ObservableObject {
    @Published private(set) var product: Product?
    @Published private(set) var isUnlocked = StoreGate.isUnlocked
    @Published private(set) var lastError: String?

    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = Task { [weak self] in
            // Transaction.updates delivers renewals/refunds/family-sharing
            // changes for the life of the process; every event re-derives
            // entitlement from scratch rather than trusting the event.
            for await _ in Transaction.updates {
                await self?.refreshEntitlement()
            }
        }
        Task { [weak self] in
            await self?.load()
            await self?.refreshEntitlement()
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    func load() async {
        do {
            product = try await Product.products(for: [StoreGate.productID]).first
        } catch {
            lastError = "store unavailable — check your connection"
        }
    }

    func purchase() async {
        guard let product else {
            await load()
            // `load()` only reports thrown errors; an empty result is silent —
            // it is what a build with no StoreKit configuration and no App
            // Store product returns. Without this the CTA looks dead: tapped,
            // nothing happens, nothing explains why.
            guard product != nil else {
                lastError = "This build cannot reach the App Store product yet."
                return
            }
            await purchase()
            return
        }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                }
                await refreshEntitlement()
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            lastError = "purchase failed — nothing was charged"
        }
    }

    /// Account-free restore: sync with the App Store, then re-derive.
    func restore() async {
        try? await AppStore.sync()
        await refreshEntitlement()
    }

    /// The single source of truth. Derives from `currentEntitlements` every
    /// time — never incrementally — and mirrors into the App Group.
    func refreshEntitlement() async {
        var unlocked = false
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let transaction) = entitlement,
               transaction.productID == StoreGate.productID,
               transaction.revocationDate == nil {
                unlocked = true
            }
        }
        StoreGate.mirror(unlocked: unlocked)
        // Read back through the gate rather than using `unlocked` directly, so
        // the app's own UI agrees with what the keyboard sees — in DEBUG that
        // includes the developer override.
        isUnlocked = StoreGate.isUnlocked
    }
}
