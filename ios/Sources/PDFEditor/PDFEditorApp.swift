import SwiftUI

@main
struct PDFEditorApp: App {
    @State private var store = FileStore.shared
    @State private var opened: URL?

    var body: some Scene {
        WindowGroup {
            HomeView(opened: $opened)
                .environment(store)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
                // "Open in PDF Editor" from Files, Mail, WhatsApp…
                .onOpenURL { url in
                    if let copy = try? store.importFile(from: url) {
                        opened = copy
                    }
                }
        }
    }
}

enum Theme {
    /// The red of the app icon.
    static let accent = Color(red: 0.86, green: 0.24, blue: 0.26)
    static let card = Color(white: 0.11)
    static let cardBorder = Color.white.opacity(0.08)
}
