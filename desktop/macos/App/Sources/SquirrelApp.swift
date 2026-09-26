import SwiftUI

@main
struct SquirrelApp: App {
    @State private var store = DownloadStore()
    @State private var updates = UpdateManager()
    @State private var settings = AppSettings()
    @State private var browsers: [String] = []
    @State private var showingSplash = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        Window("Squirrel", id: "main") {
            ZStack {
                ContentView()
                    .environment(store)
                    .environment(updates)
                    .environment(settings)
                    .task {
                        browsers = NativeMessaging.register()
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
        }

        Settings {
            SettingsView(browsers: browsers)
                .environment(store)
                .environment(updates)
                .environment(settings)
        }
    }
}
