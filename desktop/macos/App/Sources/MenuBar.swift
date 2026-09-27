import AppKit
import SwiftUI

/// The squirrel in the menu bar (Settings › General): download a link without opening the
/// window, and follow downloads. It shows the overall percentage while anything downloads.
enum MenuBar {
    /// No dot in this key: with one, SwiftUI creates the menu bar item but macOS never places it
    static let shownKey = "showMenuBarItem"
}

/// Keep running when the window closes (Settings › General): Squirrel stays in the menu bar for
/// links from browsers, the Share menu and Services, and leaves the Dock until the window reopens.
@MainActor
enum Background {
    static let keepRunningKey = "keepRunningWhenClosed"

    static var keepRunning: Bool { UserDefaults.standard.object(forKey: keepRunningKey) as? Bool ?? true }
    private static var inMenuBar: Bool { UserDefaults.standard.object(forKey: MenuBar.shownKey) as? Bool ?? true }

    /// In the Dock while the window is open, and whenever the menu bar item isn't there to reach it by
    static func updateDockIcon() {
        let hide = keepRunning && inMenuBar && !LinkInbox.shared.mainWindowIsOpen
        let policy: NSApplication.ActivationPolicy = hide ? .accessory : .regular
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }
}

struct MenuBarLabel: View {
    @Environment(DownloadStore.self) private var store

    var body: some View {
        let progress = store.activeProgress
        if progress.count > 0, let fraction = progress.fraction {
            Image(nsImage: Self.image(percent: Int(fraction * 100)))
        } else {
            Image("MenuBarIcon")
        }
    }

    /// The squirrel and the percentage drawn as one template image, since a menu bar label
    /// shows an image or text but not both.
    private static func image(percent: Int) -> NSImage {
        let icon = NSImage(named: "MenuBarIcon")
        let text = NSAttributedString(string: "\(percent)%", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.black,
        ])
        let textSize = text.size()
        let image = NSImage(size: NSSize(width: 21 + ceil(textSize.width), height: 18), flipped: false) { _ in
            icon?.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
            text.draw(at: NSPoint(x: 21, y: (18 - textSize.height) / 2))
            return true
        }
        image.isTemplate = true
        return image
    }
}

struct MenuBarPanel: View {
    @Environment(DownloadStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var link = ""
    @State private var info: VideoInfo?
    @State private var isFetching = false
    @State private var error: String?

    private var recent: [DownloadItem] {
        Array(store.items.filter(\.state.isActive) + store.items.filter { !$0.state.isActive }.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image("MenuBarIcon")
                Text("Squirrel").font(.headline)
                Spacer()
                Button { showSettings() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("Settings")
            }

            HStack(spacing: 6) {
                TextField("Paste a link", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(fetch)
                Button(action: fetch) {
                    if isFetching {
                        ProgressView().controlSize(.small).frame(width: 60)
                    } else {
                        Text("Get").frame(width: 60)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isFetching || link.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
            }

            if let info {
                formats(info)
            }

            if !recent.isEmpty {
                Divider()
                ForEach(recent) { item in
                    MenuBarDownloadRow(item: item, live: store.live[item.id])
                }
            }

            Divider()
            HStack {
                Button("Open Squirrel") { showWindow() }
                Button("Show Downloads") { NSWorkspace.shared.open(settings.downloadFolder) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 340)
        .onAppear {
            LinkInbox.shared.openMainWindow = { openWindow(id: "main") }
            // A copied link is most likely what the menu was opened for
            if link.isEmpty, info == nil, let copied = NSPasteboard.general.string(forType: .string),
               let found = LinkInbox.firstLink(in: copied) {
                link = found
            }
        }
    }

    private func formats(_ info: VideoInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(info.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Spacer()
                Button { self.info = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Cancel")
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(info.choices) { choice in
                        Button {
                            store.download(info, choice: choice)
                            self.info = nil
                            link = ""
                        } label: {
                            HStack {
                                Image(systemName: choice.isAudio ? "music.note" : "play.rectangle")
                                    .foregroundStyle(.tint)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(choice.isAudio ? "Audio · \(choice.label)" : choice.label)
                                    Text(choice.detail).font(.caption)
                                        .foregroundStyle(choice.playable == false ? Color.orange : Color.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            // A scroll view has no height of its own in a menu bar panel, so give it one
            .frame(height: min(CGFloat(info.choices.count) * 42, 250))
        }
    }

    private func fetch() {
        let url = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !isFetching else { return }
        isFetching = true
        error = nil
        Task {
            defer { isFetching = false }
            do {
                info = try await store.fetchInfo(url)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func showWindow() {
        openWindow(id: "main")
        NSApp.activate()
    }

    private func showSettings() {
        openSettings()
        NSApp.activate()
    }
}

private struct MenuBarDownloadRow: View {
    @Environment(DownloadStore.self) private var store
    let item: DownloadItem
    let live: LiveProgress?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).lineLimit(1)
                status
            }
            Spacer(minLength: 0)
            if item.state.isActive {
                Button { store.cancel(item.id) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .help("Cancel")
            } else if item.state == .finished, item.fileURL != nil {
                Button { store.reveal(item) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if item.state == .finished { store.open(item) } }
    }

    @ViewBuilder
    private var status: some View {
        switch item.state {
        case .downloading:
            ProgressView(value: live?.fraction ?? 0).controlSize(.small)
        case .queued, .extracting:
            caption("Preparing…")
        case .merging:
            caption("Finishing…")
        case .finished:
            caption(item.choice.isAudio ? "Audio" : item.choice.label)
        case .cancelled:
            caption("Cancelled")
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(1)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}
