import SwiftUI

@main
struct YTDLApp: App {
    @State private var store = DownloadStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .task { await store.startPython() }
        }
    }
}
