import AppKit
import SwiftUI

@main
struct IMessageBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            Image(systemName: state.pairings.contains(where: \.isPending)
                  ? "bubble.left.and.exclamationmark.bubble.right.fill"
                  : "bubble.left.and.bubble.right")
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let state = AppState.shared
            state.start()
            if state.agents.isEmpty || !state.fullDiskAccess {
                WindowManager.shared.showMain()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in WindowManager.shared.showMain() }
        return true
    }
}

struct MenuContent: View {
    @ObservedObject var state: AppState

    var body: some View {
        Text(state.fullDiskAccess ? state.loopbackStatus : "Needs Full Disk Access")
        if state.settings.networkEnabled { Text(state.networkStatus) }
        Text("\(state.agents.count) agent\(state.agents.count == 1 ? "" : "s") connected")
        let pending = state.pairings.filter(\.isPending)
        if !pending.isEmpty {
            Divider()
            ForEach(pending) { p in
                Button("Review pairing: \(p.agentName)…") { WindowManager.shared.showPairing(p.id) }
            }
        }
        Divider()
        Button("Open iMessage Bridge…") { WindowManager.shared.showMain() }
            .keyboardShortcut(",")
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class WindowManager {
    static let shared = WindowManager()
    private var main: NSWindow?
    private var pairingWindows: [String: NSWindow] = [:]

    func showMain() {
        if main == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: MainView(state: .shared)))
            w.title = "iMessage Bridge"
            w.setContentSize(NSSize(width: 820, height: 560))
            w.styleMask.insert([.resizable, .fullSizeContentView])
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("MainWindow")
            w.center()
            main = w
        }
        NSApp.activate(ignoringOtherApps: true)
        main?.makeKeyAndOrderFront(nil)
    }

    func showPairing(_ id: String) {
        if let w = pairingWindows[id] {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        guard let req = AppState.shared.pairing(id) else { return }
        let w = NSWindow(contentViewController: NSHostingController(rootView: PairingView(request: req)))
        w.title = "Pairing request"
        w.styleMask.remove(.resizable)
        w.styleMask.remove(.miniaturizable)
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.center()
        pairingWindows[id] = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        NSSound(named: "Glass")?.play()
    }

    func closePairing(_ id: String) {
        pairingWindows[id]?.close()
        pairingWindows[id] = nil
    }
}
