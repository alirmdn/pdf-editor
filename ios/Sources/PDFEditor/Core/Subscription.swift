import Foundation
import StoreKit

/// PDF Editor Pro: an auto-renewable subscription, $9.99 a month after a one-week free trial.
///
/// The price and the trial are set in App Store Connect, not here: the subscription
/// `Subscription.monthly` in the group `Subscription.groupID`, with an introductory offer
/// "Free, 1 week" (new subscribers only). StoreKit shows both in the user's own currency.
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
    /// The subscription group "PDF Editor Pro" in App Store Connect.
    static let groupID = "22499435"

    /// Shown with the subscribe button and in Settings, as App Review requires (guideline 3.1.2).
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyURL = URL(string: "https://aliramadann.github.io/pdf-editor-support/privacy.html")!
    static let supportURL = URL(string: "https://aliramadann.github.io/pdf-editor-support/")!
    static let supportEmail = "my.aliramadan@gmail.com"

    enum Access: Equatable {
        case checking
        case subscribed
        case locked
    }

    /// What Settings shows about the user's subscription.
    struct Details: Equatable {
        enum State: Equatable {
            case trial, active, gracePeriod, billingRetry, expired, revoked
        }

        var state: State
        /// When the user first subscribed (the trial's start, for a trial).
        var started: Date
        /// The start of the current period (this month, or the trial week).
        var periodStart: Date
        /// When the current period ends: the next renewal, or the end of access when cancelled.
        var periodEnd: Date?
        /// Whether it renews at `periodEnd`; false once cancelled.
        var willRenew: Bool

        /// Whole days left in the current period (0 on its last day).
        var daysRemaining: Int? {
            guard let end = periodEnd else { return nil }
            let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: end)).day ?? 0
            return max(0, days)
        }

        var isActive: Bool { [.trial, .active, .gracePeriod, .billingRetry].contains(state) }
    }

    private(set) var access: Access = .checking
    private(set) var details: Details?
    /// Set after a purchase that unlocked the app, to welcome the user once.
    var welcome: Details?

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

    /// Re-read the subscription from StoreKit (works offline: StoreKit caches it).
    func refresh() async {
        if Self.paywallDisabled { return }
        let found = await Self.currentDetails()
        details = found
        access = found?.isActive == true ? .subscribed : .locked
    }

    /// After the subscribe sheet: unlock straight away when the purchase went through, and
    /// welcome the user. StoreKit can take a moment to list a new subscription, so the
    /// purchase's own transaction counts until it does.
    func handle(_ result: Result<Product.PurchaseResult, Error>) async {
        guard case .success(.success(let verification)) = result, case .verified(let transaction) = verification else {
            await refresh()
            return
        }
        await transaction.finish()
        await refresh()
        if access != .subscribed, Self.productIDs.contains(transaction.productID), transaction.revocationDate == nil,
           (transaction.expirationDate ?? .distantFuture) > Date() {
            details = Self.details(for: transaction, state: Self.isTrial(transaction) ? .trial : .active, willRenew: true)
            access = .subscribed
        }
        if access == .subscribed { welcome = details }
    }

    /// "Restore Purchases": sync with the App Store, then say what was found.
    func restore() async -> String {
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            return "Restore was cancelled."
        } catch {
            await refresh()
            return "The App Store could not be reached (\(error.localizedDescription)). Check your connection and try again."
        }
        await refresh()
        guard let d = details, d.isActive else {
            return "No active PDF Editor Pro subscription was found for this Apple ID. If you subscribed with another Apple ID, sign in with it in Settings ▸ App Store."
        }
        let until = d.periodEnd.map { " until \($0.formatted(date: .long, time: .omitted))" } ?? ""
        return d.state == .trial ? "Your free trial is restored. It runs\(until)." : "Your subscription is restored. It is active\(until)."
    }

    // MARK: Reading StoreKit

    private static func currentDetails() async -> Details? {
        var best: Details?
        if let statuses = try? await Product.SubscriptionInfo.status(for: groupID) {
            for status in statuses {
                guard case .verified(let transaction) = status.transaction, productIDs.contains(transaction.productID) else { continue }
                var willRenew = false
                if case .verified(let renewal) = status.renewalInfo { willRenew = renewal.willAutoRenew }
                let state: Details.State
                switch status.state {
                case .subscribed: state = isTrial(transaction) ? .trial : .active
                case .inGracePeriod: state = .gracePeriod
                case .inBillingRetryPeriod: state = .billingRetry
                case .revoked: state = .revoked
                default: state = .expired
                }
                let d = details(for: transaction, state: state, willRenew: willRenew)
                if best == nil || (d.isActive && !(best?.isActive ?? false)) { best = d }
            }
        }
        if best != nil { return best }
        // No status (offline, or StoreKit has not caught up): the entitlements StoreKit cached.
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, productIDs.contains(transaction.productID), transaction.revocationDate == nil else { continue }
            if let expiry = transaction.expirationDate, expiry < Date() { continue }
            return details(for: transaction, state: isTrial(transaction) ? .trial : .active, willRenew: true)
        }
        return nil
    }

    private static func isTrial(_ transaction: Transaction) -> Bool {
        if #available(iOS 17.2, *) {
            return transaction.offer?.type == .introductory
        }
        return transaction.offerType == .introductory
    }

    private static func details(for transaction: Transaction, state: Details.State, willRenew: Bool) -> Details {
        Details(
            state: state,
            started: transaction.originalPurchaseDate,
            periodStart: transaction.purchaseDate,
            periodEnd: transaction.expirationDate,
            willRenew: willRenew
        )
    }
}
