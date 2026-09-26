import SwiftUI

@main
struct SquirrelApp: App {
    @State private var store = DownloadStore()
    @State private var updates = UpdateManager()
    @State private var cookies = CookieStore()
    @State private var showingSplash = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environment(store)
                    .environment(updates)
                    .environment(cookies)
                    .task {
                        await store.startPython()
                        await updates.refreshStatus()
                        await updates.autoUpdateIfDue()
                    }
                    .onChange(of: scenePhase) { _, phase in
                        // Long-lived sessions still get their daily check.
                        if phase == .active { Task { await updates.autoUpdateIfDue() } }
                    }
                if showingSplash {
                    LaunchSplash { withAnimation(.easeOut(duration: 0.25)) { showingSplash = false } }
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
        }
    }
}
