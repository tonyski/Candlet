import Foundation

nonisolated struct AppError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

nonisolated struct RPCError: LocalizedError {
    let errorDescription: String?
}

/// 子进程断开。挂起的请求和退出事件拿到的是同一个值，谁先到都不影响判断
nonisolated struct Disconnected: LocalizedError {
    let errorDescription: String?
    let needsLogin: Bool

    static let generic = Disconnected(errorDescription: "连接已断开，正在重试…", needsLogin: false)
    static let login = Disconnected(errorDescription: "未登录或登录已过期，请在终端执行 longbridge auth login，再点「重新连接」",
                                    needsLogin: true)
}

/// 管理一个长驻的 `longbridge serve` 子进程：
/// 一行一个 JSON-RPC 请求写进 stdin，从 stdout 按行读回响应（按 id 对应）和行情推送。
actor Serve {
    enum Event: Sendable {
        case push(JSON)              // quote.updated
        case exited(Disconnected)
    }

    nonisolated let events: AsyncStream<Event>
    private nonisolated let sink: AsyncStream<Event>.Continuation

    private var process: Process?
    private var input: FileHandle?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSON, any Error>] = [:]
    private var stderr = ""
    private var cli: URL?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        (events, sink) = AsyncStream.makeStream()
        // 子进程意外退出时写 stdin 会收到 SIGPIPE，默认会直接杀掉整个 App；忽略后变成可捕获的写入错误
        signal(SIGPIPE, SIG_IGN)
    }

    func start() async throws {
        guard process == nil else { return }
        if cli == nil { cli = await Self.locateCLI() }
        // 查找 CLI 时 actor 可重入，期间可能已经有别的 start() 把进程起来了
        guard process == nil else { return }
        guard let cli else {
            throw AppError("未找到 longbridge 命令，请先执行 brew install --cask longbridge/tap/longbridge-terminal")
        }

        let proc = Process()
        proc.executableURL = cli
        proc.arguments = ["serve"]
        let stdin = Pipe(), stdout = Pipe(), stderrPipe = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderrPipe

        let id = ObjectIdentifier(proc)
        proc.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Task { await self.exited(id) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // EOF 后 handler 会被反复空调用，必须摘掉，否则会一直空转
            guard !data.isEmpty, let self else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { await self.log(text) }
        }

        stderr = ""
        try proc.run()
        process = proc
        input = stdin.fileHandleForWriting

        let lines = stdout.fileHandleForReading.bytes.lines
        Task {
            do {
                for try await line in lines { receive(line, from: id) }
            } catch {}
        }
    }

    func stop() {
        let proc = process
        process = nil          // 解除关联后，旧进程的退出通知会被忽略
        input = nil
        failPending(.generic)
        proc?.terminate()
    }

    func call(_ method: String, _ params: JSON) async throws -> JSON {
        guard let input else { throw AppError("未连接") }
        nextID += 1
        let id = nextID
        var request: [String: JSON] = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method)]
        request["params"] = params
        let line = try encoder.encode(JSON.object(request)) + [0x0A]

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try input.write(contentsOf: line) } catch {
                pending.removeValue(forKey: id)?.resume(throwing: error)
            }
        }
    }

    // MARK: - 内部

    private func receive(_ line: String, from id: ObjectIdentifier) {
        // 已被 stop() 解除关联的旧进程，在真正退出前的输出一律丢弃
        guard let process, ObjectIdentifier(process) == id,
              let msg = try? decoder.decode(JSON.self, from: Data(line.utf8)) else { return }
        if let id = msg["id"]?.int {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = msg["error"] {
                continuation.resume(throwing: RPCError(errorDescription: error["message"]?.string))
            } else {
                continuation.resume(returning: msg["result"] ?? .null)
            }
        } else if msg["method"]?.string == "quote.updated", let params = msg["params"] {
            sink.yield(.push(params))
        }
    }

    private func log(_ text: String) {
        stderr = String((stderr + text).suffix(500))
    }

    private func exited(_ id: ObjectIdentifier) {
        guard let process, ObjectIdentifier(process) == id else { return }
        self.process = nil
        input = nil

        let reason = stderr.lowercased()
        let error: Disconnected = ["token", "auth", "login"].contains { reason.contains($0) } ? .login : .generic
        failPending(error)
        sink.yield(.exited(error))
    }

    private func failPending(_ error: Disconnected) {
        for continuation in pending.values { continuation.resume(throwing: error) }
        pending.removeAll()
    }

    /// GUI App 拿不到 shell 的 PATH，先查常见安装位置，再用登录 shell 兜底
    @concurrent
    private static func locateCLI() async -> URL? {
        let home = NSHomeDirectory()
        let known = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.longbridge/bin"]
            .map { "\($0)/longbridge" }
        if let path = known.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return URL(filePath: path)
        }

        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v longbridge"]
        let out = Pipe()
        shell.standardOutput = out
        guard (try? shell.run()) != nil else { return nil }
        shell.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? URL(filePath: path) : nil
    }
}
