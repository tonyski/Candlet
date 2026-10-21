import Foundation
import Synchronization

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

    static let generic = Disconnected(errorDescription: "已断开，稍后自动重连", needsLogin: false)
    static let login = Disconnected(errorDescription: "未登录长桥", needsLogin: true)
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
    /// stderr 由 readabilityHandler 在后台线程写入，退出判断时同步读取，不依赖异步任务的先后
    private nonisolated let stderr = Mutex("")
    private var stderrHandle: FileHandle?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        (events, sink) = AsyncStream.makeStream()
        // 子进程意外退出时写 stdin 会收到 SIGPIPE，默认会直接杀掉整个 App；忽略后变成可捕获的写入错误
        signal(SIGPIPE, SIG_IGN)
    }

    func start() async throws {
        guard process == nil else { return }
        let proc = Process()
        proc.executableURL = Self.cli
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
            self.log(data)
        }

        stderr.withLock { $0 = "" }
        stderrHandle = stderrPipe.fileHandleForReading
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
        stderrHandle?.readabilityHandler = nil
        stderrHandle = nil
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

    private nonisolated func log(_ data: Data) {
        stderr.withLock { $0 = String(($0 + String(decoding: data, as: UTF8.self)).suffix(500)) }
    }

    private func exited(_ id: ObjectIdentifier) {
        guard let process, ObjectIdentifier(process) == id else { return }
        self.process = nil
        input = nil

        // 进程已退出，把还没被 handler 读走的输出一次读完
        stderrHandle?.readabilityHandler = nil
        if let rest = try? stderrHandle?.readToEnd() { log(rest) }
        stderrHandle = nil
        let reason = stderr.withLock { $0.lowercased() }
        let error: Disconnected = ["token", "auth", "login"].contains { reason.contains($0) } ? .login : .generic
        failPending(error)
        sink.yield(.exited(error))
    }

    private func failPending(_ error: Disconnected) {
        for continuation in pending.values { continuation.resume(throwing: error) }
        pending.removeAll()
    }

    /// 随 App 打包的 CLI，版本由 scripts/fetch-longbridge.sh 固定
    nonisolated static let cli = Bundle.main.bundleURL.appending(path: "Contents/Helpers/longbridge")

    /// 运行 `longbridge auth login`（设备码授权）：CLI 自己打开浏览器并轮询，授权完成后退出。
    /// 输出里的授权链接交给 onURL，浏览器没打开时可以再点；取消任务会结束子进程
    @MainActor
    static func login(onURL: (URL) -> Void) async throws {
        let proc = Process()
        proc.executableURL = cli
        proc.arguments = ["auth", "login", "--client-name", "Candlet"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = out
        proc.standardInput = FileHandle.nullDevice
        let exited = AsyncStream<Int32> { done in
            proc.terminationHandler = { done.yield($0.terminationStatus); done.finish() }
        }
        try proc.run()
        try await withTaskCancellationHandler {
            var tail = ""
            for try await line in out.fileHandleForReading.bytes.lines {
                if let url = URL(string: line.trimmingCharacters(in: .whitespaces)), url.scheme == "https" { onURL(url) }
                tail = line
            }
            var status: Int32?
            for await code in exited { status = code }
            guard !Task.isCancelled else { throw CancellationError() }
            if status != 0 { throw AppError(tail.isEmpty ? "登录失败" : tail) }
        } onCancel: {
            proc.terminate()
        }
    }
}
