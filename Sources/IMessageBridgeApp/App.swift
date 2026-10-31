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
            MenuBarIcon(pending: state.pairings.contains(where: \.isPending))
        }
        .menuBarExtraStyle(.menu)
    }
}

/// The Agent Bubble template icon from the app bundle, with a dot cut into the
/// top-right corner while a pairing waits for approval. Falls back to SF Symbols
/// when the resources are missing (e.g. `swift run` outside the .app bundle).
struct MenuBarIcon: View {
    let pending: Bool

    private static let base: NSImage? = {
        guard let image = Bundle.main.image(forResource: "AgentBubbleMenuTemplate") else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    private static let badged: NSImage? = base.map { base in
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            let center = NSPoint(x: rect.maxX - 3.5, y: rect.maxY - 4)
            func circle(_ r: CGFloat) -> NSBezierPath {
                NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            }
            NSGraphicsContext.current?.compositingOperation = .clear
            circle(4.5).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            circle(3).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    var body: some View {
        if let image = pending ? Self.badged : Self.base {
            Image(nsImage: image)
        } else {
            Image(systemName: pending
                  ? "bubble.left.and.exclamationmark.bubble.right.fill"
                  : "bubble.left.and.bubble.right")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--screenshots"), i + 1 < args.count {
            Task { @MainActor in
                Screenshotter.run(to: URL(fileURLWithPath: args[i + 1]))
                NSApp.terminate(nil)
            }
            return
        }
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
