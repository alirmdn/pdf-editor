import Foundation
import StoreKit

/// PDF Editor Pro: an auto-renewable subscription, $9.99 a month after a one-week free trial.
///
/// The price and the trial are set in App Store Connect, not here: the subscription
/// `Subscription.monthly` with an introductory offer "Free, 1 week" (new subscribers only).
/// StoreKit shows both in the paywall in the user's own currency.
///
/// Builds made with `xtool dev` (debug) skip the paywall, so the app can be tried on your own
/// iPhone before the subscription exists. TestFlight and App Store builds (release) require it.
@MainActor
@Observable
final class Subscription {
    static let shared = Subscription()

    /// The product id of the monthly plan, as created in App Store Connect.
    static let monthly = "com.alirmdn.pdfeditor.pro.monthly"
    static let productIDs = [monthly]

    /// Shown under the subscribe button, as App Review requires (guideline 3.1.2).
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyURL = URL(string: "https://aliramadann.github.io/pdf-editor-support/privacy.html")!

    enum Access: Equatable {
        case checking
        case subscribed
        case locked
    }

    private(set) var access: Access = .checking

    /// Whether this build lets everyone in (a development build).
    static var paywallDisabled: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    @ObservationIgnored private var updates: Task<Void, Never>?

    private init() {
        if Self.paywallDisabled {
            access = .subscribed
            return
        }
        // Renewals, refunds, purchases on another device, Ask to Buy approvals.
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                }
                await self?.refresh()
            }
        }
        Task { await refresh() }
    }

    /// Re-read the user's current entitlements (works offline: StoreKit caches them).
    func refresh() async {
        if Self.paywallDisabled { return }
        var active = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard Self.productIDs.contains(transaction.productID), transaction.revocationDate == nil else { continue }
            if let expiry = transaction.expirationDate, expiry < Date() { continue }
            active = true
        }
        access = active ? .subscribed : .locked
    }

    /// "Restore Purchases": sync with the App Store, then re-check.
    func restore() async {
        try? await AppStore.sync()
        await refresh()
    }
}
