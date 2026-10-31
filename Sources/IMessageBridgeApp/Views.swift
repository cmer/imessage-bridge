import AppKit
import BridgeCore
import SwiftUI

enum SidebarItem: Hashable {
    case setup
    case safety
    case activity
    case network
    case agent(UUID)
}

struct MainView: View {
    @ObservedObject var state: AppState
    @StateObject private var selection: Box<SidebarItem?>

    init(state: AppState, initialSelection: SidebarItem = .setup) {
        self.state = state
        _selection = StateObject(wrappedValue: Box<SidebarItem?>(initialSelection))
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection.value) {
                Section {
                    Label("Setup", systemImage: "checklist").tag(SidebarItem.setup)
                    Label("Safety", systemImage: "checkmark.shield").tag(SidebarItem.safety)
                    Label("Activity", systemImage: "clock.arrow.circlepath").tag(SidebarItem.activity)
                    Label("Network", systemImage: "network").tag(SidebarItem.network)
                }
                Section("Agents") {
                    if state.agents.isEmpty {
                        Text("None yet").foregroundStyle(.secondary)
                    }
                    ForEach(state.agents) { a in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.name)
                            Text(a.permissionSummary).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(SidebarItem.agent(a.id))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            switch selection.value {
            case .agent(let id):
                if let agent = state.agents.first(where: { $0.id == id }) {
                    AgentDetailView(state: state, agent: agent).id(id)
                } else {
                    SetupView(state: state)
                }
            case .safety: SafetyView(state: state)
            case .activity: ActivityView(state: state)
            case .network: NetworkView(state: state)
            default: SetupView(state: state)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

// MARK: Setup

struct StatusRow<Actions: View>: View {
    let ok: Bool
    let title: String
    let detail: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack { actions }.padding(.top, 2)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

struct SetupView: View {
    @ObservedObject var state: AppState

    var pairPrompt: String {
        let cli = state.agentCLIPath
        let q = ClientSetup.shellQuote(cli)
        return """
            Connect yourself to my iMessages through the iMessage Bridge app on this Mac.

            1. First ask me one question and wait for my answer: should you have read-only access, or read and send access?
            2. Pair with exactly the access I chose. Use a name that identifies you, like "Claude Code" or "Grok Bot":
               - Read-only: \(q) pair --name "<your name>" --read
               - Read and send: \(q) pair --name "<your name>" --read --send
               The command waits while I approve it on my Mac. Tell me the 6-digit code it prints so I can check it matches.
            3. Once approved, follow the connection instructions the command prints. If you are Grok Bot, don't add a connector yourself (yours run in the cloud, not on this Mac): ask me to click "Copy Grok Bot Connector" in the app and paste it into Add a custom connector.
            4. Run \(q) status --agent "<your name>" and tell me which permissions you ended up with.
            """
    }

    var body: some View {
        Form {
            Section("macOS permissions") {
                StatusRow(ok: state.fullDiskAccess, title: "Full Disk Access",
                          detail: state.fullDiskAccess
                            ? "The app can read your Messages database and contacts."
                            : "Required to read messages. In System Settings, turn on iMessage Bridge (use + to add it from Applications if it isn't listed). If it stays orange after granting, quit and reopen the app.") {
                    if !state.fullDiskAccess {
                        Button("Open Full Disk Access Settings") { state.openPrivacySettings("Privacy_AllFiles") }
                        Button("Show App in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                    }
                }
                StatusRow(ok: state.automation == .granted, title: "Control Messages (Automation)",
                          detail: "Needed only for sending. Status: \(state.automation.label).") {
                    if state.automation != .granted {
                        Button("Request Permission") { state.requestAutomation() }
                        if state.automation == .denied {
                            Button("Open Automation Settings") { state.openPrivacySettings("Privacy_Automation") }
                        }
                    }
                }
            }
            Section("Server") {
                LabeledContent("Local endpoint", value: "\(state.localURL)/mcp")
                LabeledContent("Status", value: state.loopbackStatus)
                Toggle("Allow new pairing requests", isOn: Binding(
                    get: { state.settings.allowPairing },
                    set: { var s = state.settings; s.allowPairing = $0; state.updateSettings(s) }))
                Toggle("Open at login", isOn: Binding(
                    get: { state.launchAtLogin },
                    set: { state.setLaunchAtLogin($0) }))
            }
            Section("Connect an agent") {
                Text("Paste this into Claude, Grok or another agent that can run commands on this Mac. You approve the request here and choose its permissions.")
                    .foregroundStyle(.secondary)
                CopyableText(text: pairPrompt)
                Text("CLI: \(state.cliPath)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Setup")
    }
}

struct CopyableText: View {
    let text: String
    @StateObject private var copied = Box(false)

    var body: some View {
        HStack(alignment: .top) {
            Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied.value ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied.value = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied.value = false }
            }
        }
    }
}

// MARK: Connect to an MCP client

struct ConnectSection: View {
    let agentName: String
    let cli: String
    var checkCredential = true
    var issueToken: () -> Bool = { false }
    @StateObject private var copied = Box<String?>(nil)

    static let grokBotID = "com.anysphere.sand"

    private var grokJSON: String? {
        if !checkCredential {   // screenshot demo
            return ClientSetup.grokConnectorJSON(url: "http://127.0.0.1:7542", token: "imb_demo")
        }
        guard let c = ClientSetup.savedCredential(agent: agentName) else { return nil }
        return ClientSetup.grokConnectorJSON(url: c.url, token: c.token)
    }

    var body: some View {
        Section("Connect") {
            if checkCredential && !ClientSetup.hasCredential(agent: agentName) {
                Label("No saved credential for this agent on this Mac (it was paired elsewhere, or the file was deleted). Create a new token to connect it again; the old one stops working.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button("Create New Token") {
                    copied.value = issueToken() ? "token" : "token-failed"
                }
                if copied.value == "token-failed" {
                    Text("Couldn't save the credential file.").font(.caption).foregroundStyle(.red)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Grok Bot").font(.headline)
                Text("Copy the connector, then in Grok Bot choose **Add a custom connector** and paste. Grok Bot then calls these tools directly instead of asking to run commands. The connector includes this agent's token, which Grok stores in your xAI account; it only works from this Mac.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(copied.value == "grok" ? "Copied" : "Copy Grok Bot Connector") {
                        if let json = grokJSON { copy(json, tag: "grok") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(grokJSON == nil)
                    Button("Open Grok Bot") { openGrokBot() }
                }
                Text("Grok Bot runs command-style connectors on xAI's servers, so the connector has to point at this Mac's address instead of the command-line tool. If it shows an error, delete it and Grok Bot can still use the bridge through commands you approve.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 8) {
                Text("Claude Code").font(.headline)
                Button(copied.value == "claude" ? "Copied" : "Copy Claude Code Command") {
                    copy(ClientSetup.claudeCodeCommand(cli: cli, agent: agentName), tag: "claude")
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func copy(_ s: String, tag: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        copied.value = tag
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if copied.value == tag { copied.value = nil } }
    }

    private func openGrokBot() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ConnectSection.grokBotID) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        } else if let url = URL(string: "grokbot://") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: Agent detail

struct AgentDetailView: View {
    @ObservedObject var state: AppState
    @StateObject private var m: AgentDetailModel

    init(state: AppState, agent: AgentRecord) {
        self.state = state
        _m = StateObject(wrappedValue: AgentDetailModel(agent))
    }

    var body: some View {
        Form {
            if let taint = state.activeTaint(m.agent.id) {
                Section {
                    Label("Every send needs your confirmation until \(taint.until.formatted(date: .omitted, time: .shortened)), because \(taint.reason).",
                          systemImage: "exclamationmark.shield")
                        .foregroundStyle(.orange)
                    Button("Clear Now") { state.clearTaint(m.agent.id) }
                }
            }
            Section("Permissions") {
                Toggle("Read messages and contacts", isOn: $m.agent.canRead)
                Toggle("Send messages", isOn: $m.agent.canSend)
                Toggle("Ask me before every send", isOn: Binding(
                    get: { m.agent.confirmSends },
                    set: { new in if new { m.agent.confirmSends = true } else { m.confirmNoPrompt = true } }))
                    .disabled(!m.agent.canSend)
                    .padding(.leading, 20)
                Toggle("Hide verification codes, card and Social Security numbers", isOn: $m.agent.redactSensitive)
                Toggle("Allow connections from other computers", isOn: $m.agent.allowNetwork)
            }
            Section("Conversations") {
                Picker("Can access", selection: $m.agent.chatAccess) {
                    Text("All conversations").tag(ChatAccess.all)
                    Text("Only selected conversations").tag(ChatAccess.selected)
                }
                .pickerStyle(.radioGroup)
                if m.agent.chatAccess == .selected {
                    chatPicker
                }
            }
            ConnectSection(agentName: m.agent.name, cli: state.agentCLIPath, checkCredential: !state.isDemo,
                           issueToken: { state.issueNewToken(for: m.agent.id) })
            Section("Details") {
                LabeledContent("Token", value: "imb_…\(m.agent.tokenHint)")
                LabeledContent("Paired", value: m.agent.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Last used", value: m.agent.lastUsedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                Button("Revoke Access…", role: .destructive) { m.confirmRevoke = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(m.agent.name)
        .onChange(of: m.agent) { _, new in state.update(new) }
        .confirmationDialog("Revoke \(m.agent.name)'s access?", isPresented: $m.confirmRevoke) {
            Button("Revoke", role: .destructive) { state.revoke(m.agent.id) }
        } message: {
            Text("Its token stops working immediately. You can pair it again later.")
        }
        .confirmationDialog("Let \(m.agent.name) send without asking?", isPresented: $m.confirmNoPrompt) {
            Button("Send Without Asking", role: .destructive) { m.agent.confirmSends = false }
        } message: {
            Text("Anyone who texts you can write instructions an agent might follow. Without the confirmation dialog, nothing stops it from sending messages as you. Sends are still capped at \(AppState.sendsPerHour) per hour.")
        }
    }

    @ViewBuilder private var chatPicker: some View {
        TextField("Filter", text: $m.chatFilter)
        if m.loadingChats {
            ProgressView().controlSize(.small)
        } else if m.chats.isEmpty {
            Button("Load Conversations") { loadChats() }
                .disabled(!state.fullDiskAccess)
        } else {
            let selected = Set(m.agent.allowedChats)
            let shown = m.chats.filter { m.chatFilter.isEmpty || $0.label.localizedCaseInsensitiveContains(m.chatFilter) || $0.identifier.localizedCaseInsensitiveContains(m.chatFilter) }
            Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(shown) { c in
                        Toggle(isOn: Binding(
                            get: { selected.contains(c.identifier) },
                            set: { on in
                                if on { m.agent.allowedChats.append(c.identifier) } else { m.agent.allowedChats.removeAll { $0 == c.identifier } }
                            })) {
                            HStack {
                                Text(c.label)
                                if c.isGroup { Image(systemName: "person.3").foregroundStyle(.secondary) }
                                Spacer()
                                Text(c.lastMessageDate?.formatted(date: .abbreviated, time: .omitted) ?? "")
                                    .foregroundStyle(.secondary).font(.caption)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 280)
        }
    }

    private func loadChats() {
        m.loadingChats = true
        let service = state.service
        Task {
            let result = await Task.detached { (try? service.recentChats(limit: 400)) ?? [] }.value
            m.chats = result
            m.loadingChats = false
        }
    }
}

// MARK: Activity

struct ActivityView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Group {
            if state.activity.isEmpty {
                Text("No activity since the app started.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(state.activity) {
                    TableColumn("Time") { e in Text(e.date.formatted(date: .omitted, time: .standard)) }
                        .width(80)
                    TableColumn("Agent", value: \.agent).width(110)
                    TableColumn("Action") { e in
                        Label(e.action, systemImage: e.ok ? "checkmark" : "xmark")
                            .foregroundStyle(e.ok ? Color.primary : Color.red)
                    }
                    .width(160)
                    TableColumn("Detail", value: \.detail)
                }
            }
        }
        .navigationTitle("Activity")
    }
}

// MARK: Network

struct NetworkView: View {
    @ObservedObject var state: AppState
    @StateObject private var portText = Box("")
    @StateObject private var netPortText = Box("")

    var body: some View {
        Form {
            Section {
                Toggle("Accept connections from other computers (TLS)", isOn: Binding(
                    get: { state.settings.networkEnabled },
                    set: { var s = state.settings; s.networkEnabled = $0; state.updateSettings(s) }))
                Text("Off by default. When on, the app also listens on all network interfaces with TLS. Only agents with “Allow connections from other computers” can use it. Reaching it over Tailscale is safer than exposing it on public Wi-Fi.")
                    .font(.callout).foregroundStyle(.secondary)
                if state.settings.networkEnabled {
                    LabeledContent("Status", value: state.networkStatus)
                    LabeledContent("Address", value: "\(state.networkURL)/mcp")
                    if let fp = state.tlsFingerprint {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Certificate fingerprint (SHA-256)")
                            Text(fp).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Pair from another computer").font(.headline)
                            CopyableText(text: "imessage-bridge pair --name \"<agent>\" --read --url \(state.networkURL) --fingerprint \(fp)")
                        }
                        Button("Generate New Certificate…") { state.regenerateCertificate() }
                            .help("Agents on other computers will need to pair again.")
                    }
                }
            }
            Section("Ports") {
                LabeledContent("Local (this Mac)") {
                    TextField("", text: $portText.value).frame(width: 80).onSubmit(applyPorts)
                }
                LabeledContent("Network (TLS)") {
                    TextField("", text: $netPortText.value).frame(width: 80).onSubmit(applyPorts)
                }
                Text("Changing the local port means re-running `pair` or editing each agent's saved URL.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Network")
        .onAppear {
            portText.value = String(state.settings.port)
            netPortText.value = String(state.settings.networkPort)
        }
    }

    private func applyPorts() {
        var s = state.settings
        if let p = UInt16(portText.value), p >= 1024 { s.port = p }
        if let p = UInt16(netPortText.value), p >= 1024, p != s.port { s.networkPort = p }
        state.updateSettings(s)
        portText.value = String(s.port)
        netPortText.value = String(s.networkPort)
    }
}

// MARK: Pairing

struct PairingView: View {
    let request: PairingRequest
    @StateObject private var m: PairingModel

    init(request: PairingRequest) {
        self.request = request
        _m = StateObject(wrappedValue: PairingModel(request))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "person.badge.key.fill").font(.system(size: 32)).foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("“\(request.agentName)” wants access to your iMessages").font(.headline)
                    Text(request.viaNetwork ? "From another computer (\(request.remote))" : "From a program on this Mac")
                        .foregroundStyle(request.viaNetwork ? .orange : .secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Check that the agent shows this code:").foregroundStyle(.secondary)
                Text(request.formattedCode).font(.system(size: 34, weight: .semibold, design: .monospaced))
            }
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Read messages and contacts", isOn: $m.read)
                Toggle("Send messages", isOn: $m.send)
                Toggle("Ask me before every send", isOn: $m.confirmSends)
                    .disabled(!m.send).padding(.leading, 20)
                Toggle("Allow connections from other computers", isOn: $m.allowNetwork)
                    .disabled(request.viaNetwork)
            }
            Text("You can change these, or limit it to specific conversations, later in the app.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Deny") { AppState.shared.denyPairing(request.id) }
                    .keyboardShortcut(.cancelAction)
                Button("Approve") {
                    AppState.shared.approvePairing(request.id, read: m.read, send: m.send,
                                                   confirmSends: m.confirmSends, allowNetwork: m.allowNetwork)
                }
                .disabled(!m.read && !m.send)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: View models (@State needs Xcode's macro plugin; these don't)

final class Box<T>: ObservableObject {
    @Published var value: T
    init(_ v: T) { value = v }
}

final class AgentDetailModel: ObservableObject {
    @Published var agent: AgentRecord
    @Published var chats: [ChatSummary] = []
    @Published var chatFilter = ""
    @Published var loadingChats = false
    @Published var confirmRevoke = false
    @Published var confirmNoPrompt = false
    init(_ a: AgentRecord) { agent = a }
}

final class PairingModel: ObservableObject {
    @Published var read: Bool
    @Published var send: Bool
    @Published var confirmSends = true
    @Published var allowNetwork: Bool
    init(_ r: PairingRequest) {
        read = r.requestedRead
        send = r.requestedSend
        allowNetwork = r.viaNetwork
    }
}
