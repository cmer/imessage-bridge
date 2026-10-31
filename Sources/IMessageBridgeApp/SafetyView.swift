import AppKit
import BridgeCore
import SwiftUI

final class SafetyModel: ObservableObject {
    @Published var newRecipient = ""
    @Published var recipientError: String?
    @Published var keyDraft = ""
    @Published var editingKey = false
    @Published var testOutput: String?
    @Published var testing = false
}

struct SafetyView: View {
    @ObservedObject var state: AppState
    @StateObject private var m = SafetyModel()

    private func settingsBinding<T>(_ kp: WritableKeyPath<BridgeSettings, T>) -> Binding<T> {
        Binding(get: { state.settings[keyPath: kp] },
                set: { var s = state.settings; s[keyPath: kp] = $0; state.updateSettings(s) })
    }

    var body: some View {
        Form {
            recipients
            detection
        }
        .formStyle(.grouped)
        .navigationTitle("Safety")
    }

    // MARK: Recipients

    @ViewBuilder private var recipients: some View {
        Section {
            Toggle("Ask before sending to anyone not on this list", isOn: settingsBinding(\.confirmUnknownRecipients))
            Text("Applies to every agent, even ones allowed to send without asking. This is the main defense against a message tricking an agent into sending your information to a stranger.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Allow anyone in my contacts", isOn: settingsBinding(\.contactsAreAllowed))
                .disabled(!state.settings.confirmUnknownRecipients)
            if state.settings.allowedRecipients.isEmpty {
                Text("No recipients yet. Add them here, or tick “Always allow sending to…” in a send confirmation.")
                    .foregroundStyle(.secondary)
            }
            ForEach(state.settings.allowedRecipients, id: \.self) { handle in
                HStack {
                    VStack(alignment: .leading) {
                        Text(state.service.displayName(for: handle) ?? handle)
                        if state.service.displayName(for: handle) != nil {
                            Text(handle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(role: .destructive) { state.removeAllowedRecipient(handle) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
            }
            HStack {
                TextField("Phone number or email", text: $m.newRecipient)
                    .onSubmit(addRecipient)
                Button("Add", action: addRecipient).disabled(m.newRecipient.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let err = m.recipientError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Allowed recipients")
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

    // MARK: Detection

    @ViewBuilder private var detection: some View {
        let d = state.settings.detection
        let hasKey = state.apiKey(for: d.provider) != nil
        Section {
            Text("Checks incoming messages for text aimed at an AI (instructions, fake system messages, attempts to fool the check itself) before agents see them, using TypeSafe's Jev model. A flagged message is hidden or labeled, and the agent that read it must get your confirmation for every send over the next 30 minutes.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Check incoming messages for prompt injection", isOn: Binding(
                get: { d.enabled },
                set: { var s = state.settings; s.detection.enabled = $0; state.updateSettings(s) }))
                .disabled(!hasKey)
            if !hasKey {
                Text("Add an API key below to turn this on.").font(.caption).foregroundStyle(.orange)
            }

            Picker("Provider", selection: settingsBinding(\.detection.provider)) {
                ForEach(JevProvider.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            apiKeyRow(d.provider, hasKey: hasKey)
            LabeledContent("Model") {
                TextField(d.provider.defaultModel, text: settingsBinding(\.detection.model))
                    .frame(maxWidth: 220)
            }
            if d.provider == .openrouter {
                Toggle("Only use providers that don't store or train on messages", isOn: settingsBinding(\.detection.requireNoDataCollection))
            }

            Picker("Sensitivity", selection: settingsBinding(\.detection.sensitivity)) {
                ForEach(DetectionSensitivity.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("When a message is flagged", selection: settingsBinding(\.detection.hideFlagged)) {
                Text("Hide it from the agent").tag(true)
                Text("Show it with a warning").tag(false)
            }
            Toggle("Also check messages from people in my contacts", isOn: settingsBinding(\.detection.scanContacts))
            Text(d.scanContacts
                 ? "Every incoming message an agent reads is sent to \(d.provider == .typesafe ? "TypeSafe" : "OpenRouter") for checking."
                 : "Only messages from senders who aren't in your contacts are sent to \(d.provider == .typesafe ? "TypeSafe" : "OpenRouter") for checking.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button(m.testing ? "Testing…" : "Test With Sample Messages") {
                    m.testing = true
                    m.testOutput = nil
                    Task {
                        m.testOutput = await state.testDetection()
                        m.testing = false
                    }
                }
                .disabled(!hasKey || m.testing)
                Spacer()
                let s = state.screenStats
                Text("This session: \(s.screened) checked, \(s.flagged) flagged" + (s.cost > 0 ? String(format: ", $%.4f", s.cost) : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let out = m.testOutput {
                Text(out).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            if let err = state.screenError {
                Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Prompt injection detection (optional)")
        } footer: {
            Text("Detection is a warning system, not a guarantee: a carefully written message can slip past it. Send confirmations and the recipient list are what stop damage.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func apiKeyRow(_ provider: JevProvider, hasKey: Bool) -> some View {
        LabeledContent(provider == .typesafe ? "TypeSafe API key" : "OpenRouter API key") {
            if m.editingKey || !hasKey {
                HStack {
                    SecureField("Paste key", text: $m.keyDraft).frame(maxWidth: 220)
                    Button("Save") {
                        state.setAPIKey(m.keyDraft, for: provider)
                        m.keyDraft = ""
                        m.editingKey = false
                    }
                    .disabled(m.keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if hasKey { Button("Cancel") { m.editingKey = false; m.keyDraft = "" } }
                }
            } else {
                HStack {
                    Text("Saved in Keychain").foregroundStyle(.secondary)
                    Button("Change") { m.editingKey = true }
                    Button("Remove", role: .destructive) { state.setAPIKey(nil, for: provider) }
                }
            }
        }
    }
}
