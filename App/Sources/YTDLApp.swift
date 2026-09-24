import SwiftUI

@main
struct YTDLApp: App {
    @State private var store = DownloadStore()
    @State private var updates = UpdateManager()
    @State private var cookies = CookieStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(updates)
                .environment(cookies)
                .task {
                    await store.startPython()
                    await updates.refreshStatus()
                    await updates.checkIfDue()
                }
        }
    }
}
