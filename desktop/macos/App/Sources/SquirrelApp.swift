import AppKit
import SwiftUI

@main
struct SquirrelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = DownloadStore()
    @State private var updates = UpdateManager()
    @State private var appUpdates = AppUpdateChecker()
    @State private var settings = AppSettings()
    @State private var showingSplash = true
    @AppStorage(MenuBar.shownKey) private var showMenuBar = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        Window("Squirrel", id: "main") {
            ZStack {
                ContentView()
                    .environment(store)
                    .environment(updates)
                    .environment(settings)
                    .environment(appUpdates)
                    .environment(LinkInbox.shared)
                    .task { await appUpdates.check() }
                    .task {
                        await store.start()
                        await updates.refreshStatus()
                        await updates.autoUpdateIfDue()
                    }
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active { Task { await updates.autoUpdateIfDue() } }
                    }
                if showingSplash {
                    LaunchSplash { withAnimation(.easeOut(duration: 0.25)) { showingSplash = false } }
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .frame(minWidth: 520, minHeight: 380)
        }
        .defaultSize(width: 640, height: 520)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await checkForUpdates() } }
                    .disabled(appUpdates.status == .checking)
            }
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarPanel()
                .environment(store)
                .environment(settings)
        } label: {
            MenuBarLabel()
                .environment(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
                .environment(updates)
                .environment(settings)
                .environment(appUpdates)
        }
    }

    /// Squirrel › Check for Updates…: the answer comes as an alert, since the window may be closed.
    private func checkForUpdates() async {
        await appUpdates.checkNow()
        let alert = NSAlert()
        if let release = appUpdates.available {
            alert.messageText = "Squirrel \(release.version) is available"
            alert.informativeText = "You have \(AppUpdateChecker.currentVersion). Squirrel will download the new version, replace itself and reopen."
                + (store.hasActiveDownloads ? " This stops the downloads in progress." : "")
            alert.addButton(withTitle: "Install and Relaunch")
            alert.addButton(withTitle: "Not Now")
        } else if appUpdates.status == .failed {
            alert.messageText = "Couldn't Check for Updates"
            alert.informativeText = "Squirrel couldn't reach GitHub. Check your internet connection and try again."
        } else {
            alert.messageText = "Squirrel Is Up to Date"
            alert.informativeText = "\(AppUpdateChecker.currentVersion) is the latest version."
        }
        NSApp.activate()
        let response = alert.runModal()
        guard let release = appUpdates.available else { return }
        guard response == .alertFirstButtonReturn else {
            appUpdates.dismiss()
            return
        }
        await AppInstaller.shared.install(release)
        // Only returns if it didn't work: on success Squirrel has quit to reopen as the new version
        if case .failed(let message) = AppInstaller.shared.phase {
            let failure = NSAlert()
            failure.messageText = "Couldn't Install the Update"
            failure.informativeText = message
            failure.runModal()
        }
    }
}
