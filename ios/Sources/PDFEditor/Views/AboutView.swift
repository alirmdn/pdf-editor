import SwiftUI

/// About: the version, and the credits the bundled open-source code, fonts and models require.
struct AboutView: View {
    private let credits: [(String, String)] = [
        ("PDF engine", "Open-source components used under the MIT License (see Licence Texts)."),
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
                NavigationLink("Licence Texts") { LicenceTextView() }
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

/// The licence notices the bundled open-source components require to be included with the app.
struct LicenceTextView: View {
    static let mit = """
MIT License

Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""

    var body: some View {
        ScrollView {
            Text(Self.mit)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Licence Texts")
        .navigationBarTitleDisplayMode(.inline)
    }
}
