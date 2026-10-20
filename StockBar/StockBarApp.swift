import SwiftUI

@main
struct StockBarApp: App {
    @State private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            WatchlistView()
                .environment(store)
        } label: {
            Image(.menuBarIcon)   // 模板图，自动适配深浅色菜单栏
                .accessibilityLabel("StockBar")
        }
        .menuBarExtraStyle(.window)
    }
}
