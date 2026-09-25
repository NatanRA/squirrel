import Foundation

struct EngineError: LocalizedError {
    let message: String
    var cancelled = false

    var errorDescription: String? { message }
}

/// The download engine: the shared yt-dlp bridge running in its own bundled
/// Python process (desktop/host/squirrel_host.py), started on first use.
///
/// Requests and replies are single JSON lines matched by id, so a `progress`
/// call is answered while a `download` is still running. Everything that
/// crosses threads is `Data`; decoding happens on the caller's side.
final class Engine: @unchecked Sendable {
    static let shared = Engine()

    /// Squirrel.app/Contents/Resources/runtime (see scripts/embed_runtime.sh)
    static let runtime = Bundle.main.resourceURL!.appendingPathComponent("runtime", isDirectory: true)
    static let executable = runtime.appendingPathComponent("squirrel-host")

    private let queue = DispatchQueue(label: "Squirrel.Engine")
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]

    private init() {
        // Writing to an engine that just exited must fail the call, not kill the app.
        signal(SIGPIPE, SIG_IGN)
    }

    /// Runs `squirrel_host.cmd_<command>(args)` and returns its reply.
    func call(_ command: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
        let request = try JSONSerialization.data(withJSONObject: ["cmd": command, "args": args])
        let reply: Data = try await withCheckedThrowingContinuation { continuation in
            queue.async { self.send(request, continuation) }
        }
        guard let result = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            throw EngineError(message: "Malformed reply from the download engine")
        }
        if result["ok"] as? Bool != true {
            throw EngineError(
                message: result["error"] as? String ?? "Unknown error",
                cancelled: result["cancelled"] as? Bool ?? false)
        }
        return result
    }

    /// Stops the engine; the next call starts a fresh one (e.g. with a new yt-dlp).
    func restart() {
        queue.async {
            self.process?.terminate()
            self.stopped(self.process)
        }
    }

    // MARK: - Process (all on `queue`)

    private func send(_ request: Data, _ continuation: CheckedContinuation<Data, Error>) {
        do {
            try launchIfNeeded()
            nextID += 1
            let id = nextID
            // Splice the id into the request object: {"id":1,"cmd":...}
            var line = Data("{\"id\":\(id),".utf8)
            line.append(request.dropFirst())
            line.append(0x0A)
            pending[id] = continuation
            do {
                try input?.write(contentsOf: line)
            } catch {
                pending.removeValue(forKey: id)?.resume(throwing: error)
            }
        } catch {
            continuation.resume(throwing: error)
        }
    }

    private func launchIfNeeded() throws {
        if let process, process.isRunning { return }
        guard FileManager.default.isExecutableFile(atPath: Self.executable.path) else {
            throw EngineError(message: "The download engine is missing from Squirrel.app. Reinstall the app.")
        }
        let process = Process()
        process.executableURL = Self.executable
        process.arguments = ["--stdio"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil }
            self?.queue.async { self?.receive(chunk, from: process) }
        }
        process.terminationHandler = { [weak self] ended in
            self?.queue.async { self?.stopped(ended) }
        }
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
        buffer.removeAll()
    }

    private func receive(_ chunk: Data, from sender: Process) {
        // Late output from an engine a restart replaced would corrupt the new one's stream.
        guard sender === process else { return }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = object["id"] as? Int else { continue }
            pending.removeValue(forKey: id)?.resume(returning: Data(line))
        }
    }

    private func stopped(_ ended: Process?) {
        // Ignore a previous engine exiting after a restart already replaced it.
        guard let ended, ended === process else { return }
        process = nil
        input = nil
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values {
            continuation.resume(throwing: EngineError(message: "The download engine stopped unexpectedly"))
        }
    }
}
