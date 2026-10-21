import SwiftUI

/// About: the version, and the credits the bundled open-source code, fonts and models require.
struct AboutView: View {
    private let credits: [(String, String)] = [
        ("PdfCraft", "Open-source PDF engine by the PdfCraft contributors, used under the MIT OR Apache-2.0 licence."),
        ("Noto Sans Arabic", "Google and the Noto project. SIL Open Font License 1.1."),
        ("Japanese fonts", "BIZ UD and Shippori Mincho faces. SIL Open Font License 1.1."),
        ("PP-OCRv5 Arabic model", "PaddlePaddle Authors (PaddleOCR). Apache License 2.0."),
        ("ocrs text detection and recognition models", "Robert Knight (ocrs-models, trained on HierText). CC-BY-SA-4.0; the model files are unmodified."),
        ("Lucide icons", "Lucide contributors. ISC License."),
    ]

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PDF Editor").font(.title2.bold())
                    Text("Version \(version)").foregroundStyle(.secondary)
                    Text("Edit, sign and scan PDFs in Arabic and English. Everything works on this iPhone: no account, no tracking, and your files never leave the device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            Section("Open-source licences") {
                ForEach(credits, id: \.0) { credit in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(credit.0).font(.subheadline.weight(.semibold))
                        Text(credit.1).font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
