import SwiftUI

@main
struct PDFEditorApp: App {
    @State private var store = FileStore.shared
    @State private var opened: URL?
    @State private var subscription = Subscription.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Group {
                switch subscription.access {
                case .subscribed:
                    HomeView(opened: $opened)
                case .locked:
                    PaywallView()
                case .checking:
                    ProgressView()
                }
            }
                .fullScreenCover(isPresented: Binding(get: { subscription.welcome != nil }, set: { if !$0 { subscription.welcome = nil } })) {
                    if let details = subscription.welcome {
                        WelcomeView(details: details) { subscription.welcome = nil }
                    }
                }
                .environment(store)
                .environment(subscription)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
                // A renewal, cancellation or refund while the app was away shows on return.
                .onChange(of: phase) { _, now in
                    if now == .active { Task { await subscription.refresh() } }
                }
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
