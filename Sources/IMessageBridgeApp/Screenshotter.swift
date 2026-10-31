import AppKit
import SwiftUI

/// `iMessage Bridge --screenshots <dir>` renders the app's windows (not the
/// send alert, whose vibrancy doesn't survive offscreen drawing) with demo
/// data into PNGs (light and dark) for the website. It draws the view
/// hierarchy directly, so it needs no Screen Recording permission, never
/// shows real messages or contacts, and doesn't start the servers.
@MainActor
enum Screenshotter {
    static func run(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let demo = AppState.makeDemo()
        let grok = demo.agents[0].id
        let main = NSSize(width: 920, height: 330)

        for (name, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let ap = NSAppearance(named: name)!
            capture(MainView(state: demo, initialSelection: .setup), title: "iMessage Bridge", size: NSSize(width: 920, height: 820),
                    appearance: ap, to: dir.appendingPathComponent("setup-\(suffix).png"))
            capture(MainView(state: demo, initialSelection: .agent(grok)), title: "iMessage Bridge", size: NSSize(width: 920, height: 870),
                    appearance: ap, to: dir.appendingPathComponent("agent-\(suffix).png"))
            capture(MainView(state: demo, initialSelection: .safety), title: "iMessage Bridge", size: NSSize(width: 920, height: 800),
                    appearance: ap, to: dir.appendingPathComponent("safety-\(suffix).png"))
            capture(MainView(state: demo, initialSelection: .activity), title: "iMessage Bridge", size: main,
                    appearance: ap, to: dir.appendingPathComponent("activity-\(suffix).png"))
            capture(PairingView(request: demo.pairings[0]), title: "Pairing request", size: nil,
                    appearance: ap, to: dir.appendingPathComponent("pairing-\(suffix).png"))
        }
        print("Wrote screenshots to \(dir.path)")
    }

    private static func capture<V: View>(_ view: V, title: String, size: NSSize?, appearance: NSAppearance, to url: URL) {
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size ?? NSSize(width: 400, height: 300)),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.contentViewController = host
        window.title = title
        window.appearance = appearance
        if let size { window.setContentSize(size) } else { window.setContentSize(host.view.fittingSize) }
        snapshot(window, appearance: appearance, to: url)
        window.close()
    }

    private static func snapshot(_ window: NSWindow, appearance: NSAppearance, to url: URL) {
        window.isReleasedWhenClosed = false
        window.alphaValue = 0            // invisible: drawn into a bitmap, never on screen
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        window.displayIfNeeded()
        guard let frameView = window.contentView?.superview ?? window.contentView,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        appearance.performAsCurrentDrawingAppearance {
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
