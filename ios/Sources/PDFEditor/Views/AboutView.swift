import SwiftUI

/// About & Licences: the credits the bundled code, fonts and models require.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var managing = false

    private let credits: [(String, String)] = [
        ("PdfCraft engine", "PDF Editor is based on PdfCraft 0.9.0 by the PdfCraft contributors. MIT OR Apache-2.0. PDF Editor is not affiliated with the PdfCraft or ArtCraft teams."),
        ("Noto Sans Arabic", "Google and the Noto project. SIL Open Font License 1.1."),
        ("Japanese fonts", "BIZ UD and Shippori Mincho faces. SIL Open Font License 1.1."),
        ("PP-OCRv5 Arabic model", "PaddlePaddle Authors (PaddleOCR). Apache License 2.0."),
        ("ocrs text detection and recognition models", "Robert Knight (ocrs-models, trained on HierText). CC-BY-SA-4.0; the model files are unmodified."),
        ("Lucide icons", "Lucide contributors. ISC License."),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PDF Editor").font(.title2.bold())
                        Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                            .foregroundStyle(.secondary)
                        Text("Works offline. No account, no tracking, no data leaves this device.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                if !Subscription.paywallDisabled {
                    Section("Subscription") {
                        Button("Manage Subscription") { managing = true }
                        Button("Restore Purchases") { Task { await Subscription.shared.restore() } }
                        Link("Terms of Use", destination: Subscription.termsURL)
                        Link("Privacy Policy", destination: Subscription.privacyURL)
                    }
                }
                Section("Licences") {
                    ForEach(credits, id: \.0) { credit in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(credit.0).font(.subheadline.weight(.semibold))
                            Text(credit.1).font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .manageSubscriptionsSheet(isPresented: $managing)
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
