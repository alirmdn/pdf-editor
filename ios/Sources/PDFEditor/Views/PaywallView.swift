import StoreKit
import SwiftUI

/// The subscription screen: Apple's own subscription store view, which shows the plan, the free
/// week ("Try it free"), the price after it and the legal links, and handles the purchase sheet.
/// Shown until the user subscribes; the purchase unlocks the app at once.
struct PaywallView: View {
    @Environment(Subscription.self) private var subscription
    @State private var restoring = false
    @State private var restoreMessage: String?
    /// Between confirming with Apple and the purchase's result.
    @State private var purchasing = false
    @State private var purchaseMessage: String?

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
                    feature("signature", "Sign, initial and date forms with your finger")
                    feature("square.on.square", "Merge, split and reorder pages")
                    feature("lock.shield", "Works offline: your files never leave your iPhone")
                }
                Text(Self.disclosure)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    Task {
                        restoring = true
                        restoreMessage = await subscription.restore()
                        restoring = false
                    }
                } label: {
                    if restoring { ProgressView() } else { Text("Restore Purchases").font(.subheadline.weight(.semibold)) }
                }
                .disabled(restoring)
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
        }
        .subscriptionStoreButtonLabel(.multiline)
        // Restore is the button above, which says what it found.
        .storeButton(.hidden, for: .restorePurchases)
        .subscriptionStorePolicyDestination(url: Subscription.termsURL, for: .termsOfService)
        .subscriptionStorePolicyDestination(url: Subscription.privacyURL, for: .privacyPolicy)
        .onInAppPurchaseStart { _ in purchasing = true }
        .onInAppPurchaseCompletion { _, result in
            let message = await subscription.handle(result)
            purchasing = false
            purchaseMessage = message
        }
        .overlay {
            if purchasing {
                ZStack {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    VStack(spacing: 16) {
                        LogoMark(size: 72, animating: true)
                        Text("Processing your subscription…").font(.headline)
                        Text("This can take a few seconds. Please keep the app open.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                    .padding(32)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: purchasing)
        .alert("Subscription", isPresented: Binding(get: { purchaseMessage != nil }, set: { if !$0 { purchaseMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(purchaseMessage ?? "")
        }
        // A subscription made on another device, or approved later (Ask to Buy), unlocks too.
        .subscriptionStatusTask(for: Subscription.groupID) { _ in
            await subscription.refresh()
        }
        .alert("Restore Purchases", isPresented: Binding(get: { restoreMessage != nil }, set: { if !$0 { restoreMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(restoreMessage ?? "")
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }

    /// The auto-renewal terms App Review asks to be shown with the subscribe button.
    static let disclosure = "Free for 7 days, then the monthly price shown, charged to your Apple ID when the trial ends. The subscription renews every month unless you cancel at least 24 hours before the end of the current period. Manage or cancel any time in Settings ▸ your name ▸ Subscriptions."

    private func feature(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).font(.subheadline)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Theme.accent)
        }
    }
}

/// Shown once right after subscribing: the trial's or period's dates, then the app.
struct WelcomeView: View {
    let details: Subscription.Details
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.accent)
            Text("Welcome to PDF Editor Pro").font(.title.bold()).multilineTextAlignment(.center)
            if let end = details.periodEnd {
                Text(details.state == .trial
                     ? "Your free trial is active until \(end.formatted(date: .long, time: .omitted)). You won't be charged before then, and you can cancel any time in Settings."
                     : "Your subscription is active. It renews on \(end.formatted(date: .long, time: .omitted)).")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Text("Your plan and its dates are always in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onContinue) {
                Text("Start Editing").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }
}
