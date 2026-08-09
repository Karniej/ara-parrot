import Foundation
import StoreKit

enum StorePhase: Equatable {
    case idle
    case purchasing
    case purchased
    case pending
    case restoring
    case restored
    case nothingToRestore
    case failed(String)
}

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
    @Published private(set) var phase: StorePhase = .idle

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
        lastError = nil
        do {
            product = try await Product.products(for: [StoreGate.productID]).first
        } catch {
            lastError = "store unavailable — check your connection"
            phase = .failed("That didn't go through")
        }
    }

    func purchase() async {
        phase = .purchasing
        lastError = nil
        guard let product else {
            await load()
            // `load()` only reports thrown errors; an empty result is silent —
            // it is what a build with no StoreKit configuration and no App
            // Store product returns. Without this the CTA looks dead: tapped,
            // nothing happens, nothing explains why.
            guard product != nil else {
                lastError = "This build cannot reach the App Store product yet."
                phase = .failed("That didn't go through")
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
                phase = isUnlocked ? .purchased : .failed("That didn't go through")
            case .userCancelled:
                phase = .idle
            case .pending:
                phase = .pending
            @unknown default:
                phase = .failed("That didn't go through")
            }
        } catch {
            lastError = "purchase failed — nothing was charged"
            phase = .failed("That didn't go through")
        }
    }

    /// Account-free restore: sync with the App Store, then re-derive.
    func restore() async {
        phase = .restoring
        lastError = nil
        do {
            try await AppStore.sync()
            await refreshEntitlement()
            phase = isUnlocked ? .restored : .nothingToRestore
        } catch {
            lastError = "restore failed — nothing changed"
            phase = .failed("That didn't go through")
        }
    }

    func resetPhase() {
        phase = .idle
        lastError = nil
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
