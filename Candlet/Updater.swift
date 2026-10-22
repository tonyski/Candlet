import AppKit
import Security

/// 通过 GitHub 最新 Release 检查更新：启动时和之后每天查一次（菜单栏 App 很少重启），也可以在 ⋯ 菜单里手动检查。
/// 有 DMG 时在 App 内下载安装，装不了就退回浏览器下载
@Observable
final class Updater {
    enum State: Equatable {
        case checking, upToDate, failed
        case available(version: String, url: URL)
        case installing(version: String)
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

    /// 检查期间菜单项不可点，不会重复发起；安装中不打断
    func check() {
        if case .installing = state { return }
        state = .checking
        Task { state = await Self.fetch(current: current) }
    }

    /// 下载、校验签名、替换当前 App 后重启。没有 DMG、所在目录不可写（如从 DMG 里直接运行）、签名不符等情况，改用浏览器下载
    func install() {
        guard case .available(let version, let url) = state else { return }
        state = .installing(version: version)
        Task {
            do {
                Self.relaunch(try await Self.replace(Bundle.main.bundleURL, with: url))
            } catch {
                state = .available(version: version, url: url)
                NSWorkspace.shared.open(url)
            }
        }
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

    // MARK: - 安装

    /// 新版先拷到与 App 同一卷的临时目录，校验通过后再换名替换，失败时把旧版放回原处
    @concurrent
    private static func replace(_ target: URL, with dmg: URL) async throws -> URL {
        let files = FileManager.default
        guard dmg.pathExtension == "dmg", files.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw AppError("无法就地更新")
        }
        let (download, _) = try await URLSession.shared.download(from: dmg)
        let work = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? files.removeItem(at: work) }
        let image = work.appending(path: "update.dmg"), mount = work.appending(path: "mount")
        let staged = work.appending(path: "Candlet.app"), old = work.appending(path: "old.app")
        try files.moveItem(at: download, to: image)

        try await run("/usr/bin/hdiutil", "attach", image.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path)
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
        else { throw AppError("新版签名校验失败") }
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
