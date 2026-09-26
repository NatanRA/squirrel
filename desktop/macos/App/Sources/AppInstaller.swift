import AppKit
import SwiftUI
import Observation

/// Installs a new version of Squirrel from inside the app. A disk image a browser downloads is
/// marked as coming from the internet, so macOS makes you approve the unsigned app again after
/// every update. One downloaded here isn't marked, so the new version just opens.
@MainActor
@Observable
final class AppInstaller {
    static let shared = AppInstaller()

    enum Phase: Equatable {
        case idle
        case downloading(version: String)
        case installing(version: String)
        case failed(String)
    }

    private(set) var phase = Phase.idle

    var isBusy: Bool {
        switch phase {
        case .downloading, .installing: true
        case .idle, .failed: false
        }
    }

    private static let staging = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Squirrel/Update", isDirectory: true)

    /// Downloads the release's disk image, puts the new app in place of this one and reopens it.
    func install(_ release: AppUpdateChecker.Release) async {
        guard !isBusy else { return }
        guard let download = release.download else {
            NSWorkspace.shared.open(release.page)
            return
        }
        phase = .downloading(version: release.version)
        do {
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: Self.staging)
            try fileManager.createDirectory(at: Self.staging, withIntermediateDirectories: true)

            let (file, response) = try await URLSession.shared.download(from: download)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("The download failed.") }
            let image = Self.staging.appendingPathComponent("Squirrel.dmg")
            try fileManager.moveItem(at: file, to: image)

            phase = .installing(version: release.version)
            let newApp = try await Self.unpack(image, expecting: release.version)

            let current = Bundle.main.bundleURL
            let folder = current.deletingLastPathComponent()
            guard fileManager.isWritableFile(atPath: folder.path) else {
                // Can't replace it here (e.g. no permission): open the disk image to drag it in by
                // hand. It was downloaded here too, so macOS still won't ask to verify it.
                NSWorkspace.shared.open(image)
                phase = .failed("Squirrel can't replace itself in \(folder.lastPathComponent). Drag the new Squirrel into Applications.")
                return
            }
            // Next to the current app, so the swap is a rename on the same disk
            let staged = folder.appendingPathComponent(".Squirrel-\(release.version).app")
            try? fileManager.removeItem(at: staged)
            try await Self.run("/usr/bin/ditto", [newApp.path, staged.path])
            try? fileManager.removeItem(at: newApp)

            Self.swapAfterQuit(current: current, with: staged, image: image)
            NSApp.terminate(nil)
        } catch {
            phase = .failed((error as? Failure)?.message ?? error.localizedDescription)
        }
    }

    /// Copies the app out of the disk image, after checking it's an intact Squirrel of that version.
    private static func unpack(_ image: URL, expecting version: String) async throws -> URL {
        let mount = staging.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try await run("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer {
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", mount.path, "-force"]
            detach.standardOutput = FileHandle.nullDevice
            try? detach.run()
            detach.waitUntilExit()
        }

        let app = mount.appendingPathComponent("Squirrel.app")
        let bundle = Bundle(url: app)
        guard bundle?.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version else {
            throw Failure("The download isn't Squirrel \(version).")
        }
        do {
            try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        } catch {
            throw Failure("The download is damaged. Try again.")
        }
        let copy = staging.appendingPathComponent("Squirrel.app")
        try await run("/usr/bin/ditto", [app.path, copy.path])
        return copy
    }

    /// Once Squirrel has quit, a small script moves the new app into its place and opens it. If the
    /// swap fails, the old app stays and the disk image opens to drag the new one in by hand.
    private static func swapAfterQuit(current: URL, with staged: URL, image: URL) {
        let script = """
            while kill -0 "$0" 2>/dev/null; do sleep 0.2; done
            backup="$2.old"
            rm -rf "$backup"
            if mv "$1" "$backup"; then
                if mv "$2" "$1"; then
                    rm -rf "$backup" "$4"
                    open "$1"
                    exit 0
                fi
                mv "$backup" "$1"
            fi
            rm -rf "$2"
            open "$1"
            open "$3"
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, String(ProcessInfo.processInfo.processIdentifier),
                             current.path, staged.path, image.path, staging.path]
        try? process.run()
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: Failure("\((tool as NSString).lastPathComponent) failed (\(process.terminationStatus))."))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    private struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}

/// Install for a newer release, or how it's going: in the window's banner and Settings › Updates.
struct InstallUpdateButton: View {
    @Environment(DownloadStore.self) private var store
    let release: AppUpdateChecker.Release
    private let installer = AppInstaller.shared

    var body: some View {
        switch installer.phase {
        case .downloading:
            progress("Downloading…")
        case .installing:
            progress("Installing…")
        case .idle, .failed:
            if case .failed(let message) = installer.phase {
                Text(message).foregroundStyle(.red).lineLimit(2)
            }
            Button("Install and Relaunch") { Task { await installer.install(release) } }
                .buttonStyle(.borderedProminent)
                .disabled(store.hasActiveDownloads)
                .help(store.hasActiveDownloads ? "Wait for downloads to finish" : "Download Squirrel \(release.version) and reopen")
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
    }
}
