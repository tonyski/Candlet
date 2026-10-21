import Foundation

/// 通过 GitHub 最新 Release 检查更新：启动时和之后每天查一次（菜单栏 App 很少重启），也可以在 ⋯ 菜单里手动检查
@Observable
final class Updater {
    enum State: Equatable {
        case checking, upToDate, failed
        case available(version: String, url: URL)
    }

    private(set) var state = State.checking
    let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    private static let latest = URL(string: "https://api.github.com/repos/tonyski/Candlet/releases/latest")!

    init() {
        Task {
            while true {
                check()
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }
    }

    /// 检查期间菜单项不可点，不会重复发起
    func check() {
        state = .checking
        Task { state = await Self.fetch(current: current) }
    }

    private static func fetch(current: String) async -> State {
        guard let (data, _) = try? await URLSession.shared.data(from: latest),
              let release = try? JSONDecoder().decode(JSON.self, from: data),
              let tag = release["tag_name"]?.string,
              let page = release["html_url"]?.string.flatMap(URL.init(string:))
        else { return .failed }

        let version = tag.trimmingPrefix("v")
        guard version.compare(current, options: .numeric) == .orderedDescending else { return .upToDate }
        // 有 DMG 附件就直接下载，否则打开 Release 页面
        let dmg = release["assets"]?.list()
            .compactMap { $0["browser_download_url"]?.string }
            .first { $0.hasSuffix(".dmg") }
            .flatMap(URL.init(string:))
        return .available(version: String(version), url: dmg ?? page)
    }
}
