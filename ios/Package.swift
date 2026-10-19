// swift-tools-version: 6.0
//
// PDF Editor for iPhone and iPad: a SwiftUI app over the shared Rust engine.
//
// The engine (crates/mobile, built by build-ios.sh) is a static library in Vendor/ios-arm64.
// The same package builds with xtool (testing on your iPhone) and opens in Xcode (release).

import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "PDFEditor",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "PDFEditor", targets: ["PDFEditor"]),
    ],
    targets: [
        // The C interface of the Rust engine (pe_engine_new, pe_call, …).
        .target(
            name: "CPDFEditorCore",
            path: "Sources/CPDFEditorCore",
            linkerSettings: [
                .unsafeFlags(["-L\(root)/Vendor/ios-arm64"]),
                .linkedLibrary("pdfeditor_core"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "PDFEditor",
            dependencies: ["CPDFEditorCore"],
            path: "Sources/PDFEditor"
        ),
    ],
    swiftLanguageModes: [.v5]
)
