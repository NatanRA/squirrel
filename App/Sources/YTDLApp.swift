import SwiftUI

@main
struct YTDLApp: App {
    @State private var store = DownloadStore()
    @State private var updates = UpdateManager()
    @State private var cookies = CookieStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
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
        }
    }
}
