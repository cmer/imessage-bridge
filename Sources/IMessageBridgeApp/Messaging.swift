import AppKit
import BridgeCore
import Foundation

enum AutomationStatus: Equatable {
    case granted
    case denied
    case notDetermined
    case messagesNotRunning
    case unknown(Int32)

    var label: String {
        switch self {
        case .granted: return "Allowed"
        case .denied: return "Denied"
        case .notDetermined: return "Not requested yet"
        case .messagesNotRunning: return "Open Messages to check"
        case .unknown(let c): return "Unknown (\(c))"
        }
    }
}

/// Talks to Messages.app and owns the send-confirmation dialog.
@MainActor
enum Messaging {
    nonisolated static let messagesBundleID = "com.apple.MobileSMS"
    private static var confirmationOpen = false

    /// Checks (or with `ask`, requests) the Automation → Messages permission.
    /// Asking blocks until the user answers, so it runs off the main thread.
    nonisolated static func automationStatus(ask: Bool) -> AutomationStatus {
        var target = AEAddressDesc()
        let id = messagesBundleID
        let created = id.withCString { ptr in
            AECreateDesc(typeApplicationBundleID, ptr, id.utf8.count, &target)
        }
        guard created == noErr else { return .unknown(Int32(created)) }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(procNotFound): return .messagesNotRunning
        default: return .unknown(status)
        }
    }

    /// Native dialog showing the full message. Cancel is the default button;
    /// closing, timing out or any failure means "don't send".
    struct Confirmation {
        var approved = false
        var alwaysAllowRecipient = false
        var stopAsking = false
    }

    /// `warnings` explain why the dialog appeared (new recipient, flagged
    /// reads). `offerAllowRecipient` adds an "Always allow sending to…" box;
    /// `offerStopAsking` adds "Don't ask again" for the agent's own
    /// ask-before-every-send setting. Both only count if the user sends.
    static func confirmSend(agent: String, to: String, name: String?, service: String, text: String,
                            warnings: [String] = [], offerAllowRecipient: Bool = false,
                            offerStopAsking: Bool = false) -> Confirmation {
        guard !confirmationOpen else { return Confirmation() }
        confirmationOpen = true
        defer { confirmationOpen = false }

        NSApp.activate(ignoringOtherApps: true)
        let (alert, boxes) = makeAlert(agent: agent, to: to, name: name, service: service, text: text,
                                       warnings: warnings, offerAllowRecipient: offerAllowRecipient,
                                       offerStopAsking: offerStopAsking)

        let timer = Timer(timeInterval: 60, repeats: false) { _ in NSApp.abortModal() }
        RunLoop.main.add(timer, forMode: .modalPanel)
        let response = alert.runModal()
        timer.invalidate()
        let approved = response == .alertSecondButtonReturn
        return Confirmation(approved: approved,
                            alwaysAllowRecipient: approved && boxes.allowRecipient?.state == .on,
                            stopAsking: approved && boxes.stopAsking?.state == .on)
    }

    struct Checkboxes {
        var allowRecipient: NSButton?
        var stopAsking: NSButton?
    }

    /// The confirmation alert, built separately so screenshot mode can render it.
    static func makeAlert(agent: String, to: String, name: String?, service: String, text: String,
                          warnings: [String], offerAllowRecipient: Bool,
                          offerStopAsking: Bool = false) -> (NSAlert, Checkboxes) {
        let alert = NSAlert()
        alert.alertStyle = warnings.isEmpty ? .warning : .critical
        alert.messageText = "\(agent) wants to send a message"
        let who = name.map { "\($0) (\(to))" } ?? to
        var info = "To: \(who)\nVia: \(service)"
        if !warnings.isEmpty {
            info += "\n\n" + warnings.map { "⚠︎ " + $0 }.joined(separator: "\n")
        }
        info += "\n\nRead the full message below before sending."
        alert.informativeText = info

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 160))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: scroll.bounds)
        tv.string = text
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 4, height: 4)
        scroll.documentView = tv

        var boxes = Checkboxes()
        var rows: [NSView] = [scroll]
        if offerAllowRecipient {
            let box = NSButton(checkboxWithTitle: "Always allow sending to \(who)", target: nil, action: nil)
            boxes.allowRecipient = box
            rows.append(box)
        }
        if offerStopAsking {
            let box = NSButton(checkboxWithTitle: "Don't ask again for \(agent)'s messages", target: nil, action: nil)
            box.toolTip = "Turns off \"Ask me before every send\" for \(agent). You can turn it back on from its page."
            boxes.stopAsking = box
            rows.append(box)
            let note = NSTextField(wrappingLabelWithString:
                "You'll still be asked before it sends to anyone not on your recipient list, or after it reads a message that was flagged.")
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            note.textColor = .secondaryLabelColor
            note.preferredMaxLayoutWidth = 380
            rows.append(note)
        }
        if rows.count == 1 {
            alert.accessoryView = scroll
        } else {
            let stack = NSStackView(views: rows)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            stack.setCustomSpacing(12, after: scroll)
            scroll.widthAnchor.constraint(equalToConstant: 380).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: 160).isActive = true
            stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
            alert.accessoryView = stack
        }

        let cancel = alert.addButton(withTitle: "Don't Send")
        cancel.keyEquivalent = "\r"
        let send = alert.addButton(withTitle: "Send")
        send.keyEquivalent = ""
        return (alert, boxes)
    }

    static func send(to: String, text: String, service: String) throws {
        let svc = service == "SMS" ? "SMS" : "iMessage"
        let script = """
            set msgBody to "\(escape(text))"
            tell application "Messages"
                set svc to 1st service whose service type = \(svc)
                send msgBody to buddy "\(escape(to))" of svc
            end tell
            """
        guard let apple = NSAppleScript(source: script) else {
            throw BridgeError.failed("could not build the AppleScript")
        }
        var err: NSDictionary?
        apple.executeAndReturnError(&err)
        if let err {
            let msg = err[NSAppleScript.errorMessage] as? String ?? "\(err)"
            let num = err[NSAppleScript.errorNumber] as? Int ?? 0
            if num == -1743 {
                throw BridgeError.forbidden("macOS blocked sending: allow iMessage Bridge to control Messages in System Settings → Privacy & Security → Automation.")
            }
            throw BridgeError.failed("Messages could not send: \(msg)")
        }
    }

    /// AppleScript string literal escaping (backslash first). Text is already
    /// validated to contain no control characters other than \n \r \t.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
