import StoreKit
import SwiftUI

/// Settings: the subscription and its dates, the saved signature, privacy and support, About.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(FileStore.self) private var store
    @State private var subscription = Subscription.shared
    @State private var managing = false
    @State private var redeeming = false
    @State private var restoring = false
    @State private var message: String?
    @State private var managingKind: SignatureStore.Kind?
    @State private var confirmingDelete = false
    /// Bumped when the saved signature changes, so its row updates.
    @State private var signatureRevision = 0

    var body: some View {
        NavigationStack {
            List {
                subscriptionSection
                signatureSection
                privacySection
                supportSection
                Section {
                    NavigationLink { AboutView() } label: { Label("About PDF Editor", systemImage: "info.circle") }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .manageSubscriptionsSheet(isPresented: $managing, subscriptionGroupID: Subscription.groupID)
            .offerCodeRedemption(isPresented: $redeeming) { _ in Task { await subscription.refresh() } }
            .sheet(isPresented: Binding(get: { managingKind != nil }, set: { if !$0 { managingKind = nil; signatureRevision += 1 } })) {
                if let kind = managingKind { SignaturePicker(kind: kind) { _ in signatureRevision += 1 } }
            }
            .alert("PDF Editor", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
            .confirmationDialog("Delete All My Data?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete All PDFs and Signatures", role: .destructive) { deleteAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes every PDF in PDF Editor and your saved signature and initials from this iPhone. It can't be undone. Your subscription is not affected.")
            }
            .task { await subscription.refresh() }
        }
    }

    // MARK: Subscription

    @ViewBuilder
    private var subscriptionSection: some View {
        Section {
            if Subscription.paywallDisabled {
                Text("Development build: no subscription needed.").foregroundStyle(.secondary)
            } else if let d = subscription.details {
                row("Plan", "PDF Editor Pro, monthly")
                row("Status", status(d))
                row("Subscribed since", day(d.started))
                row(d.state == .trial ? "Trial started" : "This period started", day(d.periodStart))
                if let end = d.periodEnd {
                    row(endLabel(d), day(end))
                }
                if d.isActive, let days = d.daysRemaining {
                    row("Days remaining", days == 1 ? "1 day" : "\(days) days")
                }
                row("Auto-renew", d.willRenew ? "On" : "Off")
            } else {
                row("Status", "Not subscribed")
            }
            if !Subscription.paywallDisabled {
                Button { managing = true } label: { Label("Manage or Cancel Subscription", systemImage: "creditcard") }
                Button {
                    Task {
                        restoring = true
                        message = await subscription.restore()
                        restoring = false
                    }
                } label: {
                    HStack {
                        Label("Restore Purchases", systemImage: "arrow.clockwise")
                        if restoring { Spacer(); ProgressView() }
                    }
                }
                .disabled(restoring)
                Button { redeeming = true } label: { Label("Redeem Offer Code", systemImage: "giftcard") }
            }
        } header: {
            Text("Subscription")
        } footer: {
            if !Subscription.paywallDisabled {
                Text("Payment is handled by Apple. Cancel at least 24 hours before the renewal date to avoid the next charge.")
            }
        }
    }

    private func status(_ d: Subscription.Details) -> String {
        switch d.state {
        case .trial: return d.willRenew ? "Free trial" : "Free trial, cancelled"
        case .active: return d.willRenew ? "Active" : "Active, cancelled"
        case .gracePeriod: return "Payment problem: update your payment method"
        case .billingRetry: return "Payment problem: Apple is retrying"
        case .expired: return "Expired"
        case .revoked: return "Refunded"
        }
    }

    private func endLabel(_ d: Subscription.Details) -> String {
        switch d.state {
        case .trial: return d.willRenew ? "Trial ends, first charge" : "Trial ends"
        case .active, .gracePeriod, .billingRetry: return d.willRenew ? "Renews on" : "Ends on"
        case .expired, .revoked: return "Ended on"
        }
    }

    // MARK: Signature

    private var signatureSection: some View {
        Section {
            let _ = signatureRevision
            Button { managingKind = .signature } label: {
                LabeledContent {
                    Text("\(SignatureStore.saved(.signature).count) of \(SignatureStore.limit)")
                } label: {
                    Label("Signatures", systemImage: "signature")
                }
            }
            Button { managingKind = .initials } label: {
                LabeledContent {
                    Text("\(SignatureStore.saved(.initials).count) of \(SignatureStore.limit)")
                } label: {
                    Label("Initials", systemImage: "pencil.tip")
                }
            }
            if SignatureStore.exists(.signature) || SignatureStore.exists(.initials) {
                Button(role: .destructive) {
                    SignatureStore.clear()
                    signatureRevision += 1
                } label: { Label("Forget All Saved Signatures", systemImage: "trash") }
            }
        } header: {
            Text("Signature")
        } footer: {
            Text("Up to \(SignatureStore.limit) signatures and \(SignatureStore.limit) initials are kept on this iPhone only, to sign documents in a tap.")
        }
    }

    // MARK: Privacy

    private var privacySection: some View {
        Section {
            Label("No account, no ads, no tracking", systemImage: "hand.raised")
            Label("Your PDFs are edited on this iPhone and never uploaded", systemImage: "iphone")
            Link(destination: Subscription.privacyURL) { Label("Privacy Policy", systemImage: "lock.doc") }
            Link(destination: Subscription.termsURL) { Label("Terms of Use", systemImage: "doc.text") }
            Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete All My Data", systemImage: "trash") }
        } header: {
            Text("Privacy")
        } footer: {
            Text("PDF Editor collects no personal data. The camera is used only when you scan a document, and text recognition runs on this iPhone.")
        }
    }

    private func deleteAll() {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: store.folder, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: url)
        }
        SignatureStore.clear()
        signatureRevision += 1
        store.refresh()
        message = "All your PDFs and your saved signature have been deleted from this iPhone."
    }

    // MARK: Support

    private var supportSection: some View {
        Section("Support") {
            Button {
                if let url = URL(string: "mailto:\(Subscription.supportEmail)?subject=PDF%20Editor%20support") { openURL(url) }
            } label: { Label("Contact Support", systemImage: "envelope") }
            Link(destination: Subscription.supportURL) { Label("Help Website", systemImage: "questionmark.circle") }
        }
    }

    // MARK: Rows

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value)
    }

    private func day(_ date: Date) -> String { date.formatted(date: .long, time: .omitted) }
}
