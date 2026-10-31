import AppKit
import BridgeCore
import SwiftUI

/// The Safety page follows the path a message takes: what checks it on the
/// way in, before an agent reads it, and what stops it on the way out, before
/// an agent sends. A summary at the top shows that path and what's on.
final class SafetyModel: ObservableObject {
    @Published var newRecipient = ""
    @Published var recipientError: String?
    @Published var showingJevSettings = false
    @Published var testing = false
    @Published var testResults: [DetectionSample]?
}

final class JevSheetModel: ObservableObject {
    @Published var keyDraft = ""
    @Published var editingKey = false
}

struct SafetyView: View {
    @ObservedObject var state: AppState
    @StateObject private var m = SafetyModel()

    private var d: DetectionSettings { state.settings.detection }
    private var hasJevKey: Bool { state.apiKey(for: d.provider) != nil }
    private var localActive: Bool { d.useLocalModel && state.localModelInstalled }
    private var jevActive: Bool { d.useJev && hasJevKey }
    private var jevVendor: String { d.provider == .typesafe ? "TypeSafe" : "OpenRouter" }

    private func binding<T>(_ kp: WritableKeyPath<BridgeSettings, T>) -> Binding<T> {
        Binding(get: { state.settings[keyPath: kp] },
                set: { var s = state.settings; s[keyPath: kp] = $0; state.updateSettings(s) })
    }

    var body: some View {
        Form {
            summary
            incoming
            outgoing
        }
        .formStyle(.grouped)
        .navigationTitle("Safety")
        .sheet(isPresented: $m.showingJevSettings) {
            JevSettingsSheet(state: state)
        }
    }

    // MARK: Summary

    @ViewBuilder private var summary: some View {
        let screening = state.screeningActive
        let stats = state.screenStats
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: screening ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                        .font(.system(size: 28))
                        .foregroundStyle(screening ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(screening ? "Incoming messages are screened" : "Incoming messages aren't screened")
                            .font(.title3.weight(.semibold))
                        Text(screening
                             ? "This session: \(stats.screened) checked, \(stats.flagged) flagged"
                                + (stats.cost > 0 ? String(format: ", $%.4f", stats.cost) : "")
                             : state.settings.confirmUnknownRecipients
                                ? "Turn on a check below. Sends to people not on your list still need your OK."
                                : "Turn on a check below.")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                FlowStrip(steps: [
                    .init(label: "Patterns", symbol: "text.magnifyingglass", on: screening),
                    .init(label: "On this Mac", symbol: "desktopcomputer", on: localActive),
                    .init(label: "Jev", symbol: "cloud", on: jevActive),
                    .init(label: "Recipient list", symbol: "person.crop.circle.badge.checkmark",
                          on: state.settings.confirmUnknownRecipients),
                ])
                if let err = state.screenError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: Incoming

    @ViewBuilder private var incoming: some View {
        Section {
            CheckRow(symbol: "desktopcomputer", title: "On this Mac",
                     detail: "Llama Prompt Guard 2 catches jailbreaks and attempts to override an agent's instructions. Free, and messages never leave this Mac. Built with Llama.") {
                localModelControl
            }
            if case .failed(let message) = state.modelDownload {
                Label(message, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            }

            CheckRow(symbol: "cloud", title: "Jev",
                     detail: "TypeSafe's model also catches polite requests to an agent and tricks aimed at the check. Sends the messages it checks to \(jevVendor).") {
                if hasJevKey {
                    Button("Settings…") { m.showingJevSettings = true }
                    Toggle("Jev", isOn: binding(\.detection.useJev)).labelsHidden()
                } else {
                    Button("Add API Key…") { m.showingJevSettings = true }
                }
            }

            if state.screeningActive {
                Picker("When a message is flagged", selection: binding(\.detection.hideFlagged)) {
                    Text("Hide it from the agent").tag(true)
                    Text("Show it with a warning").tag(false)
                }
                LabeledContent {
                    Picker("Sensitivity", selection: binding(\.detection.sensitivity)) {
                        ForEach([DetectionSensitivity.low, .balanced, .high], id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                } label: {
                    Text("Sensitivity")
                    Text("Strict flags more messages, including some harmless ones.")
                }
                Toggle("Also screen messages from my contacts", isOn: binding(\.detection.scanContacts))
                testRow
            }
        } header: {
            Text("Before an agent reads a message")
        } footer: {
            Text("Screening is an alarm, not a guarantee. An agent that reads a flagged message needs your OK for every send over the next 30 minutes.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var localModelControl: some View {
        switch state.modelDownload {
        case .downloading(let fraction):
            ProgressView(value: fraction).frame(width: 120)
            Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
            Button { state.cancelModelDownload() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Cancel download")
        case .installing:
            ProgressView().controlSize(.small)
            Text("Installing…").foregroundStyle(.secondary)
        case .idle, .failed:
            if state.localModelInstalled {
                Menu {
                    if state.localModelUpdateAvailable {
                        Button("Update Model") { state.downloadLocalModel() }
                    }
                    Button("Remove Model", role: .destructive) { state.removeLocalModel() }
                } label: {
                    Image(systemName: state.localModelUpdateAvailable ? "arrow.down.circle" : "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(state.localModelUpdateAvailable ? "A newer model is available" : "Model options")
                Toggle("On this Mac", isOn: binding(\.detection.useLocalModel)).labelsHidden()
            } else if PromptGuardAsset.isPublished {
                Button("Download (\(ByteCountFormatter.string(fromByteCount: PromptGuardAsset.byteCount, countStyle: .file)))") {
                    state.downloadLocalModel()
                }
            } else {
                Text("Not available yet").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var testRow: some View {
        HStack {
            Text("Try the checks on four sample messages")
            Spacer()
            if m.testing { ProgressView().controlSize(.small) }
            Button(m.testResults == nil ? "Run Test" : "Run Again") {
                m.testing = true
                Task {
                    m.testResults = await state.testDetection()
                    m.testing = false
                }
            }
            .disabled(m.testing)
        }
        if let results = m.testResults {
            DetectionResultsGrid(results: results)
        }
    }

    // MARK: Outgoing

    @ViewBuilder private var outgoing: some View {
        Section {
            Toggle(isOn: binding(\.confirmUnknownRecipients)) {
                Text("Ask before sending to anyone not on this list")
                Text("Applies to every agent, even ones allowed to send without asking. No message wording can get past it.")
            }
            Toggle("Allow anyone in my contacts", isOn: binding(\.contactsAreAllowed))
                .disabled(!state.settings.confirmUnknownRecipients)
            ForEach(state.settings.allowedRecipients, id: \.self) { handle in
                let name = state.service.displayName(for: handle)
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name ?? handle)
                        if name != nil { Text(handle).font(.callout).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button { state.removeAllowedRecipient(handle) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove \(name ?? handle)")
                }
            }
            HStack {
                TextField("Add a phone number or email", text: $m.newRecipient)
                    .textFieldStyle(.plain)
                    .onSubmit(addRecipient)
                Button("Add", action: addRecipient)
                    .disabled(m.newRecipient.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let err = m.recipientError {
                Text(err).font(.callout).foregroundStyle(.red)
            }
        } header: {
            Text("Before an agent sends a message")
        } footer: {
            if state.settings.allowedRecipients.isEmpty {
                Text("You can also add people from a send confirmation, with “Always allow sending to…”.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func addRecipient() {
        do {
            try state.addAllowedRecipient(m.newRecipient)
            m.newRecipient = ""
            m.recipientError = nil
        } catch {
            m.recipientError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}

// MARK: - Pieces

/// One check: an icon, a name and one line about it, and its control on the right.
struct CheckRow<Control: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            HStack(spacing: 8) { control }
        }
        .padding(.vertical, 4)
    }
}

/// The path a message takes: the checks before an agent reads it, then the
/// recipient check before anything is sent. Checks that are off are dimmed.
struct FlowStrip: View {
    struct Step: Identifiable {
        var id: String { label }
        let label: String
        let symbol: String
        let on: Bool
    }

    let steps: [Step]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(showLabels: true)
            row(showLabels: false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(steps.map { "\($0.label) \($0.on ? "on" : "off")" }.joined(separator: ", "))
    }

    private func row(showLabels: Bool) -> some View {
        HStack(spacing: 6) {
            endpoint("envelope", "Message in")
            ForEach(steps) { step in
                arrow
                chip(step, showLabel: showLabels)
            }
            arrow
            endpoint("paperplane", "Sent")
        }
        .fixedSize()
    }

    private var arrow: some View {
        Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
    }

    private func endpoint(_ symbol: String, _ help: String) -> some View {
        Image(systemName: symbol).foregroundStyle(.secondary).help(help)
    }

    private func chip(_ step: Step, showLabel: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: step.symbol)
            if showLabel { Text(step.label) }
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .foregroundStyle(step.on ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
        .background {
            Capsule().fill(step.on ? AnyShapeStyle(Color.green.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.5)))
        }
        .overlay {
            if !step.on { Capsule().strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 2])) }
        }
        .help("\(step.label): \(step.on ? "on" : "off")")
    }
}

/// Sample messages down the side, one column per check.
struct DetectionResultsGrid: View {
    let results: [DetectionSample]

    var body: some View {
        if let first = results.first {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    ForEach(first.verdicts) { Text($0.check).font(.caption.weight(.medium)).foregroundStyle(.secondary) }
                }
                ForEach(results) { sample in
                    GridRow {
                        Text(sample.name)
                        ForEach(sample.verdicts) { VerdictLabel(verdict: $0) }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

struct VerdictLabel: View {
    let verdict: DetectionSample.Verdict

    var body: some View {
        Group {
            switch verdict.flagged {
            case true?: Label("Flagged", systemImage: "exclamationmark.shield.fill").foregroundStyle(.red)
            case false?: Label("Passed", systemImage: "checkmark").foregroundStyle(.secondary)
            case nil: Label("Error", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .font(.callout)
        .help(verdict.note)
    }
}

/// Jev's provider, key and model, in a sheet so the page stays short.
struct JevSettingsSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var m = JevSheetModel()

    private var provider: JevProvider { state.settings.detection.provider }

    private func binding<T>(_ kp: WritableKeyPath<DetectionSettings, T>) -> Binding<T> {
        Binding(get: { state.settings.detection[keyPath: kp] },
                set: { var s = state.settings; s.detection[keyPath: kp] = $0; state.updateSettings(s) })
    }

    var body: some View {
        let hasKey = state.apiKey(for: provider) != nil
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "cloud").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Jev").font(.title3.weight(.semibold))
                    Text("TypeSafe's prompt-injection model, through TypeSafe or OpenRouter.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding([.horizontal, .top], 20)
            Form {
                Section {
                    Picker("Get Jev from", selection: binding(\.provider)) {
                        Text("TypeSafe").tag(JevProvider.typesafe)
                        Text("OpenRouter").tag(JevProvider.openrouter)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: provider) { _, _ in m.editingKey = false; m.keyDraft = "" }

                    LabeledContent("API key") {
                        if m.editingKey || !hasKey {
                            HStack {
                                SecureField("Paste key", text: $m.keyDraft)
                                    .frame(minWidth: 180)
                                    .onSubmit(saveKey)
                                Button("Save", action: saveKey)
                                    .disabled(m.keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        } else {
                            HStack {
                                Label("In Keychain", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                Button("Change") { m.editingKey = true }
                                Button("Remove", role: .destructive) { state.setAPIKey(nil, for: provider) }
                            }
                        }
                    }
                    if provider == .openrouter {
                        Toggle("Only use providers that don't store or train on messages",
                               isOn: binding(\.requireNoDataCollection))
                    }
                } footer: {
                    Link(provider == .typesafe ? "Get a key from TypeSafe" : "Get a key from OpenRouter",
                         destination: URL(string: provider == .typesafe ? "https://typesafe.ai" : "https://openrouter.ai/keys")!)
                        .font(.callout)
                }
                Section {
                    DisclosureGroup("Advanced") {
                        LabeledContent("Model") {
                            TextField(provider.defaultModel, text: binding(\.model)).frame(maxWidth: 200)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
            .padding(.top, 4)
        }
        .frame(width: 480)
        .navigationTitle("Jev")
    }

    private func saveKey() {
        guard !m.keyDraft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        state.setAPIKey(m.keyDraft, for: provider)
        m.keyDraft = ""
        m.editingKey = false
    }
}
