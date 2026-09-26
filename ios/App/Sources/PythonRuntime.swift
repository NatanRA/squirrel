import Foundation
import JavaScriptCore
import VideoToolbox

struct BridgeError: LocalizedError {
    let message: String
    var log: [String] = []
    var cancelled = false

    var errorDescription: String? { message }
}

/// Owns the embedded CPython interpreter and calls into `ytdl_bridge.py`.
///
/// All calls run on dedicated threads with a large stack: yt-dlp can recurse
/// deeply and GCD's 512 KB worker stacks are not enough for CPython.
/// Arguments and results cross threads as JSON strings.
actor PythonRuntime {
    static let shared = PythonRuntime()

    private var startTask: Task<String, Error>?

    /// Starts the interpreter once; returns the bundled yt-dlp version.
    @discardableResult
    func start() async throws -> String {
        if startTask == nil {
            startTask = Task.detached(priority: .userInitiated) {
                var settings: [String: Any] = [
                    "cache_dir": AppPaths.ytdlpCache.path,
                    "cookie_file": CookieStore.cookieFile.path,
                    // Decides whether 1440p/4K (AV1-only on YouTube) plays natively
                    "av1_decode": VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1),
                ]
                #if DEBUG
                settings["verbose"] = true
                #endif
                let config = try Self.encode(settings)
                let json = try await Self.onPythonThread {
                    pybridge_set_js_runner(jsRunner)
                    // Read by ytdl_updater.py before yt-dlp is imported.
                    setenv("YTDL_UPDATE_DIR", AppPaths.pythonUpdates.path, 1)
                    if let error = pybridge_initialize(Bundle.main.resourcePath!) {
                        defer { free(error) }
                        throw BridgeError(message: "Python failed to start: \(String(cString: error))")
                    }
                    return Self.invoke("configure", config)
                }
                return try Self.decode(json)["version"] as? String ?? "unknown"
            }
        }
        return try await startTask!.value
    }

    /// Calls `ytdl_bridge.<function>(json)` and returns the decoded result.
    nonisolated func call(_ function: String, _ args: [String: Any]) async throws -> [String: Any] {
        let json = try Self.encode(args)
        try await start()
        return try Self.decode(await Self.onPythonThread { Self.invoke(function, json) })
    }

    private static func encode(_ args: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
    }

    private static func invoke(_ function: String, _ json: String) -> String {
        let raw = pybridge_call(function, json)
        defer { free(raw) }
        return String(cString: raw)
    }

    private static func decode(_ json: String) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw BridgeError(message: "Malformed response from Python")
        }
        if result["ok"] as? Bool != true {
            throw BridgeError(
                message: result["error"] as? String ?? "Unknown error",
                log: result["log"] as? [String] ?? [],
                cancelled: result["cancelled"] as? Bool ?? false)
        }
        return result
    }

    private static func onPythonThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                continuation.resume(with: Result { try body() })
            }
            thread.stackSize = 16 << 20
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }
}

// MARK: - JavaScriptCore runner for yt-dlp's YouTube challenge solver

private let jsRunner: pybridge_js_runner_t = { code, isError in
    let (output, error) = JSCRunner.run(String(cString: code))
    if let error {
        isError.pointee = 1
        return strdup(error)
    }
    return strdup(output)
}

enum JSCRunner {
    /// Evaluates `script` in a fresh context and returns what it logged.
    static func run(_ script: String) -> (output: String, error: String?) {
        autoreleasepool {
            guard let context = JSContext() else { return ("", "Could not create JSContext") }
            var output = ""
            var error: String?

            let log: @convention(block) () -> Void = {
                let args = JSContext.currentArguments() as? [JSValue] ?? []
                output += args.map { $0.toString() ?? "" }.joined(separator: " ") + "\n"
            }
            let console = JSValue(newObjectIn: context)!
            console.setObject(log, forKeyedSubscript: "log" as NSString)
            context.setObject(console, forKeyedSubscript: "console" as NSString)
            context.exceptionHandler = { _, exception in
                error = exception?.toString() ?? "Unknown JavaScript error"
            }

            context.evaluateScript(script)
            return (output, error)
        }
    }
}
