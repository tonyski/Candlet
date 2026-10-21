import SwiftUI

@main
struct CandletApp: App {
    @State private var store = Store()
    @State private var updater = Updater()

    init() { LoginItem.enableOnFirstLaunch() }

    var body: some Scene {
        MenuBarExtra {
            WatchlistView()
                .environment(store)
                .environment(updater)
        } label: {
            Image(.menuBarIcon)
                .accessibilityLabel("Candlet")
        }
        .menuBarExtraStyle(.window)
    }
}
