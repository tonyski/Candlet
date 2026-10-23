import AppKit
import Security

/// 通过 GitHub 最新 Release 检查更新：打开面板时检查（菜单栏 App 很少重启，按打开面板算比按启动算及时），也可以在 ⋯ 菜单里手动检查。
/// 有 DMG 时在 App 内下载安装，装不了就说明原因，由用户决定是否改用浏览器下载
@Observable
final class Updater {
    /// GitHub 上的一个新版本：page 是 Release 页面（更新内容），dmg 是安装包
    struct Release: Equatable {
        let version: String
        let page: URL
        let dmg: URL?
    }

    enum State: Equatable {
        case checking, upToDate, failed
        case available(Release)
        case installing(Release)
    }

    private(set) var state = State.checking
    let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var lastChecked = Date.distantPast

    private static let latest = URL(string: "https://api.github.com/repos/tonyski/Candlet/releases/latest")!
    /// 自动检查的间隔；上次失败（比如开机时还没联网）则下次打开面板立即重查
    private static let interval: TimeInterval = 6 * 3600

    func panelOpened() {
        if case .failed = state { return check() }
        if Date.now.timeIntervalSince(lastChecked) > Self.interval { check() }
    }

    /// 检查期间菜单项不可点，不会重复发起；安装中不打断
    func check() {
        guard checkTask == nil else { return }
        if case .installing = state { return }
        state = .checking
        checkTask = Task {
            state = await Self.fetch(current: current)
            if state != .failed { lastChecked = .now }
            checkTask = nil
        }
    }

    /// 下载、校验签名、替换当前 App 后重启。没有 DMG 时直接打开 Release 页面；
    /// 所在目录不可写（如从 DMG 里直接运行）、下载失败、签名不符时说明原因，可以改用浏览器下载
    func install() {
        guard case .available(let release) = state else { return }
        guard let dmg = release.dmg else {
            NSWorkspace.shared.open(release.page)
            return
        }
        state = .installing(release)
        Task {
            do {
                Self.relaunch(try await Self.replace(Bundle.main.bundleURL, with: dmg))
            } catch {
                state = .available(release)
                Self.explain(error, release)
            }
        }
    }

    /// 菜单栏面板里的 SwiftUI 弹窗不可靠，和删除分组一样用系统提醒框
    private static func explain(_ error: any Error, _ release: Release) {
        let alert = NSAlert()
        alert.messageText = "无法自动更新到 \(release.version)"
        alert.informativeText = error.localizedDescription + "\n\n可以在浏览器中下载安装包，拖进「应用程序」替换旧版。"
        alert.addButton(withTitle: "在浏览器中下载")
        alert.addButton(withTitle: "取消")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.dmg ?? release.page) }
    }

    private static func fetch(current: String) async -> State {
        guard let release = await JSON.fetch(latest),
              let tag = release["tag_name"]?.string,
              let page = release["html_url"]?.string.flatMap(URL.init(string:))
        else { return .failed }

        let version = tag.trimmingPrefix("v")
        guard version.compare(current, options: .numeric) == .orderedDescending else { return .upToDate }
        let dmg = release["assets"]?.list()
            .compactMap { $0["browser_download_url"]?.string }
            .first { $0.hasSuffix(".dmg") }
            .flatMap(URL.init(string:))
        return .available(Release(version: String(version), page: page, dmg: dmg))
    }

    // MARK: - 安装

    /// 新版先拷到与 App 同一卷的临时目录，校验通过后再换名替换，失败时把旧版放回原处
    @concurrent
    private static func replace(_ target: URL, with dmg: URL) async throws -> URL {
        let files = FileManager.default
        guard files.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw AppError("Candlet 所在的文件夹不可写，比如正直接从安装包里运行。")
        }
        let (download, _) = try await URLSession.shared.download(from: dmg)
        let work = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? files.removeItem(at: work) }
        let image = work.appending(path: "update.dmg"), mount = work.appending(path: "mount")
        let staged = work.appending(path: "Candlet.app"), old = work.appending(path: "old.app")
        try files.moveItem(at: download, to: image)

        do {
            try await run("/usr/bin/hdiutil", "attach", image.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path)
        } catch {
            throw AppError("安装包无法打开，可能下载不完整。")
        }
        let copied = Result { try files.copyItem(at: mount.appending(path: "Candlet.app"), to: staged) }
        try? await run("/usr/bin/hdiutil", "detach", mount.path, "-force")
        try copied.get()
        try verify(staged)

        try files.moveItem(at: target, to: old)
        do { try files.moveItem(at: staged, to: target) } catch {
            try? files.moveItem(at: old, to: target)
            throw error
        }
        return target
    }

    /// 新版必须满足当前 App 的指定要求（同一 Bundle ID、同一开发者证书）；开发版是临时签名，不会通过
    private nonisolated static func verify(_ app: URL) throws {
        var running: SecCode?, own: SecStaticCode?, requirement: SecRequirement?, update: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &own) == errSecSuccess, let own,
              SecCodeCopyDesignatedRequirement(own, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &update) == errSecSuccess, let update,
              SecStaticCodeCheckValidity(update, flags, requirement) == errSecSuccess
        else { throw AppError("新版的签名与当前版本不符，为安全起见没有安装。") }
    }

    private nonisolated static func run(_ tool: String, _ arguments: String...) async throws {
        let proc = Process()
        proc.executableURL = URL(filePath: tool)
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
            proc.terminationHandler = { $0.terminationStatus == 0 ? done.resume() : done.resume(throwing: AppError("\(tool) 失败")) }
            do { try proc.run() } catch { done.resume(throwing: error) }
        }
    }

    /// 等当前进程退出后再打开新版，菜单栏里不会同时出现两个
    private static func relaunch(_ app: URL) {
        let opener = Process()
        opener.executableURL = URL(filePath: "/bin/sh")
        opener.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"", app.path]
        guard (try? opener.run()) != nil else { return }
        NSApp.terminate(nil)
    }
}
