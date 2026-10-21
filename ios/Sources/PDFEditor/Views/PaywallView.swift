import StoreKit
import SwiftUI

/// The subscription screen: Apple's own subscription store view, which shows the plan, the free
/// week ("Try it free"), the price after it, Restore Purchases and the legal links, and handles the
/// purchase sheet. Shown until the user subscribes.
struct PaywallView: View {
    @Environment(Subscription.self) private var subscription

    var body: some View {
        SubscriptionStoreView(productIDs: Subscription.productIDs) {
            VStack(spacing: 18) {
                Image(systemName: "doc.richtext.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.accent)
                Text("PDF Editor Pro")
                    .font(.largeTitle.bold())
                VStack(alignment: .leading, spacing: 10) {
                    feature("pencil.line", "Edit the text of any PDF, Arabic included")
                    feature("text.viewfinder", "Turn scans into editable, searchable text")
                    feature("signature", "Fill, sign and annotate")
                    feature("square.on.square", "Merge, split and reorder pages")
                    feature("lock.shield", "Works offline: your files never leave your iPhone")
                }
                Text("Try it free for 7 days. Cancel anytime in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
        }
        .subscriptionStoreButtonLabel(.multiline)
        .storeButton(.visible, for: .restorePurchases)
        .subscriptionStorePolicyDestination(url: Subscription.termsURL, for: .termsOfService)
        .subscriptionStorePolicyDestination(url: Subscription.privacyURL, for: .privacyPolicy)
        .onInAppPurchaseCompletion { _, _ in
            await subscription.refresh()
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }

    private func feature(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).font(.subheadline)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Theme.accent)
        }
    }
}
