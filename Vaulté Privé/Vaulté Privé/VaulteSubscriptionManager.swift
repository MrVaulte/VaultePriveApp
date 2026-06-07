//
//  VaulteSubscriptionManager.swift
//  Vaulté Privé
//
//  StoreKit 2 subscriptions — three tiers.
//
//  ┌──────────────────────────────────────────────────────────────────┐
//  │  FREE                                                            │
//  │  • E2E encrypted messaging (Double Ratchet / X3DH)              │
//  │  • Encrypted voice calls (ChaCha20-Poly1305, per-frame)         │
//  │  • Unlimited conversations                                        │
//  │  • Disappearing messages (custom timer: 10s → 7 days)           │
//  │  • Screenshot & copy controls (always enforced)                  │
//  │  • Certificate-pinned relay connection                           │
//  ├──────────────────────────────────────────────────────────────────┤
//  │  PREMIER  $59.99 / year  ·  $6.99 / month                       │
//  │  Everything in Free, plus:                                       │
//  │  • Encrypted local backup & restore (AES-256-GCM)               │
//  │  • Full-text message search (on-device, encrypted index)         │
//  │  • Message delivery & read receipts                              │
//  │  • Custom conversation nicknames                                  │
//  ├──────────────────────────────────────────────────────────────────┤
//  │  ELITE  $299.99 / year  ·  $29.99 / month                       │
//  │  Everything in Premier, plus:                                    │
//  │  • One Time Pad (OTP) — information-theoretically secure         │
//  │  • Verified OTP — Ed25519-signed pad bundles with TOFU binding   │
//  │  • Trusted device roster                                          │
//  └──────────────────────────────────────────────────────────────────┘
//
//  Real prices come from App Store Connect; for local dev attach
//  `VaultePremiumSubscriptions.storekit` in the scheme (Run → Options).
//

import Foundation
import Observation
import StoreKit

// MARK: - Access level helpers

enum VerifiedOtpAccessLevel: Sendable {
    case none
    case premierLimited   // Can import/prepare bundles; cannot use OTP in chat
    case eliteFull        // Full OTP + Verified OTP messaging
}

// MARK: - VaulteSubscriptionManager

@MainActor
@Observable
final class VaulteSubscriptionManager {
    static let shared = VaulteSubscriptionManager()

    // ── Premier ──────────────────────────────────────────────────────────
    static let premierAnnualProductId     = "com.vaulteprive.premium.premier.annual"
    static let premierMonthlyProductId    = "com.vaulteprive.premium.premier.monthly"
    /// Grandfathered — same entitlements as Premier.
    static let legacyPersonalAnnualId     = "com.vaulteprive.premium.personal.annual"

    // ── Elite ─────────────────────────────────────────────────────────────
    static let eliteAnnualProductId       = "com.vaulteprive.premium.elite.annual"
    static let eliteMonthlyProductId      = "com.vaulteprive.premium.elite.monthly"
    /// Grandfathered — same entitlements as Elite.
    static let legacyProAnnualId          = "com.vaulteprive.premium.pro.annual"

    // ── No free-tier conversation limit ───────────────────────────────────
    // Unlimited conversations are available on all tiers.

    private(set) var products: [Product] = []
    private(set) var purchasedProductIds: Set<String> = []
    private(set) var isLoading = false
    var lastError: String?

    private var updatesTask: Task<Void, Never>?

    // MARK: - Computed tier flags

    var hasPremierSubscription: Bool {
        purchasedProductIds.contains(Self.premierAnnualProductId)
            || purchasedProductIds.contains(Self.premierMonthlyProductId)
            || purchasedProductIds.contains(Self.legacyPersonalAnnualId)
    }

    var hasEliteSubscription: Bool {
        purchasedProductIds.contains(Self.eliteAnnualProductId)
            || purchasedProductIds.contains(Self.eliteMonthlyProductId)
            || purchasedProductIds.contains(Self.legacyProAnnualId)
    }

    /// Premier or Elite: unlocks backup, search, delivery receipts.
    var hasPremiumAccess: Bool {
        hasPremierSubscription || hasEliteSubscription
    }

    /// Elite only: OTP, Verified OTP, device roster.
    var hasEliteAccess: Bool {
        hasEliteSubscription
    }

    // MARK: - Feature gates (use these in UI/logic)

    // ── Free on all tiers ─────────────────────────────────────────────────
    /// Unlimited E2E conversations — always free.
    var conversationLimit: Int? { nil }
    /// Disappearing messages — always available.
    var canUseDisappearingMessages: Bool { true }
    /// Screenshot & copy controls — always enforced (privacy is not a premium feature).
    var canUseScreenshotControls: Bool { true }

    // ── Premier+ ──────────────────────────────────────────────────────────
    /// Encrypted backup & restore.
    var canUseEncryptedBackup: Bool { hasPremiumAccess }
    /// Full-text on-device message search.
    var canUseMessageSearch: Bool { hasPremiumAccess }
    /// Message delivery & read receipts.
    var canUseDeliveryReceipts: Bool { hasPremiumAccess }
    /// Custom conversation nicknames.
    var canUseCustomNicknames: Bool { hasPremiumAccess }

    // ── Elite only ────────────────────────────────────────────────────────
    /// One Time Pad messaging.
    var canUseOTP: Bool { hasEliteAccess }
    /// Trusted device roster.
    var canUseDeviceRoster: Bool { hasEliteAccess }

    // MARK: - Verified OTP (multi-level)

    /// Verified OTP is a separate stronger mode: Elite unlocks full use,
    /// Premier gets limited preparation/import access (bundle management only).
    var verifiedOtpAccessLevel: VerifiedOtpAccessLevel {
        if hasEliteSubscription { return .eliteFull }
        if hasPremierSubscription { return .premierLimited }
        return .none
    }

    var hasVerifiedOtpAccess: Bool { verifiedOtpAccessLevel != .none }
    var hasVerifiedOtpFullAccess: Bool { verifiedOtpAccessLevel == .eliteFull }

    // MARK: - Lifecycle

    private init() {
        updatesTask = Task { [weak self] in
            for await _ in Transaction.updates {
                await self?.refreshPurchasedEntitlements()
            }
        }
    }

    func start() async {
        await loadProducts()
        await refreshPurchasedEntitlements()
    }

    // MARK: - StoreKit

    func loadProducts() async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        do {
            products = try await Product.products(
                for: [
                    Self.premierAnnualProductId,
                    Self.premierMonthlyProductId,
                    Self.eliteAnnualProductId,
                    Self.eliteMonthlyProductId,
                ]
            )
            .sorted { $0.price < $1.price }
        } catch {
            lastError = error.localizedDescription
            products = []
        }
    }

    func refreshPurchasedEntitlements() async {
        var ids = Set<String>()
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement else { continue }
            ids.insert(transaction.productID)
        }
        purchasedProductIds = ids
    }

    func product(id: String) -> Product? {
        products.first(where: { $0.id == id })
    }

    func purchase(_ product: Product) async throws {
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            switch verification {
            case .verified(let transaction):
                await transaction.finish()
                await refreshPurchasedEntitlements()
            case .unverified(_, let error):
                throw error
            }
        case .userCancelled:
            break
        case .pending:
            break
        @unknown default:
            break
        }
    }

    func restorePurchases() async throws {
        try await AppStore.sync()
        await refreshPurchasedEntitlements()
    }
}
