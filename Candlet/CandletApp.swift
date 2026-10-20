import SwiftUI

@main
struct CandletApp: App {
    @State private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            WatchlistView()
                .environment(store)
        } label: {
            Image(.menuBarIcon)
                .accessibilityLabel("Candlet")
        }
        .menuBarExtraStyle(.window)
    }
}
