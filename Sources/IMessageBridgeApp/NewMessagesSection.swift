import AppKit
import BridgeCore
import SwiftUI

final class WebhookFormModel: ObservableObject {
    /// The URL fields are showing: the webhook is on, or being set up.
    @Published var open: Bool
    @Published var urlDraft: String
    @Published var urlError: String?
    @Published var testing = false
    @Published var testResult: WebhookResult?
    @Published var copied = false
    @Published var confirmNewSecret = false

    init(_ e: EventSettings) {
        open = e.webhookEnabled
        urlDraft = e.webhookURL
    }
}

/// The agent page's "New messages" section: what events carry, and the webhook.
struct NewMessagesSection: View {
    @ObservedObject var state: AppState
    @ObservedObject var webhooks: WebhookDispatcher
    @ObservedObject var m: AgentDetailModel
    @StateObject private var w: WebhookFormModel

    init(state: AppState, m: AgentDetailModel) {
        self.state = state
        self.webhooks = state.webhooks
        self.m = m
        _w = StateObject(wrappedValue: WebhookFormModel(m.agent.eventSettings))
    }

    private var e: EventSettings { m.agent.eventSettings }

    var body: some View {
        Section {
            Toggle(isOn: $m.agent.eventSettings.includeText) {
                Text("Include message text")
                Text(e.includeText
                     ? "Events carry the text, redacted and screened the same way as when the agent reads it."
                     : "Events only say who wrote. The agent reads the messages itself, which screens them.")
            }
            Toggle(isOn: Binding(get: { w.open }, set: setWebhook)) {
                Text("Send a webhook")
                Text("Posts each event to an address you choose, signed so the receiver can check it came from this Mac.")
            }
            if !w.open, let note = e.webhookDisabledNote {
                Label(note, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            }
            if w.open { webhookRows }
        } header: {
            Text("New messages")
        } footer: {
            Text("Only messages other people send, in conversations this agent can access.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .onChange(of: e.webhookEnabled) { _, on in
            if !on { w.open = false }   // turned off after repeated failures
        }
        .confirmationDialog("Make a new signing secret?", isPresented: $w.confirmNewSecret) {
            Button("Make New Secret", role: .destructive) {
                webhooks.newSecret(for: m.agent.id)
                w.copied = false
            }
        } message: {
            Text("The receiver will need the new secret. Deliveries signed with it fail the old one's check.")
        }
    }

    @ViewBuilder private var webhookRows: some View {
        LabeledContent("URL") {
            HStack {
                TextField("URL", text: $w.urlDraft, prompt: Text("https://example.com/hooks/imessage"))
                    .labelsHidden()
                    .onSubmit { commitURL() }
                if w.urlDraft != e.webhookURL || !e.webhookEnabled {
                    Button("Save") { commitURL() }
                }
            }
        }
        if let err = w.urlError {
            Label(err, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
        }
        HStack {
            deliveryStatus
            Spacer()
            if w.testing { ProgressView().controlSize(.small) }
            Button("Send Test") { sendTest() }
                .disabled(w.testing || w.urlDraft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if let r = w.testResult {
            Label(r.ok ? "Test delivered (\(r.summary))." : "Test failed: \(r.summary).",
                  systemImage: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(r.ok ? .green : .orange)
        }
        LabeledContent {
            HStack {
                Button(w.copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(webhooks.secret(for: m.agent.id), forType: .string)
                    w.copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { w.copied = false }
                }
                Button("New Secret…") { w.confirmNewSecret = true }
            }
        } label: {
            Text("Signing secret")
            Text("Check deliveries with it using any Standard Webhooks library.")
        }
    }

    @ViewBuilder private var deliveryStatus: some View {
        let s = webhooks.status[m.agent.id]
        let waiting = (s?.pending ?? 0) > 0 ? " \(s!.pending) waiting." : ""
        if !e.webhookEnabled {
            Text("Save an address to start sending.").font(.callout).foregroundStyle(.secondary)
        } else if let s, let r = s.lastResult, let at = s.lastAttempt {
            if r.ok {
                Label("Last delivered \(at.formatted(.relative(presentation: .named))).\(waiting)", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            } else if let since = s.failingSince {
                Label("Failing since \(since.formatted(date: .omitted, time: .shortened)) (\(r.summary)). Retrying; turns off after \(WebhookDispatcher.duration(Webhook.giveUpAfter)) of failures.\(waiting)",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            } else {
                Label("Last delivery failed (\(r.summary)).\(waiting)", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
        } else {
            Text("Nothing sent yet. Events go out as messages arrive.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func setWebhook(_ on: Bool) {
        w.testResult = nil
        w.urlError = nil
        if on {
            w.open = true
            if !w.urlDraft.trimmingCharacters(in: .whitespaces).isEmpty { commitURL() }
        } else {
            w.open = false
            m.agent.eventSettings.webhookEnabled = false
        }
    }

    /// Saves the address and turns the webhook on, if the address is allowed.
    private func commitURL() {
        do {
            let url = try Webhook.validate(w.urlDraft)
            w.urlDraft = url.absoluteString
            w.urlError = nil
            webhooks.secret(for: m.agent.id)   // made on first use
            var e = m.agent.eventSettings
            e.webhookURL = url.absoluteString
            e.webhookEnabled = true
            e.webhookDisabledNote = nil
            m.agent.eventSettings = e
        } catch {
            w.urlError = error.localizedDescription
        }
    }

    private func sendTest() {
        w.testing = true
        w.testResult = nil
        let agent = m.agent
        let url = w.urlDraft
        Task { @MainActor in
            w.testResult = await webhooks.sendTest(agent, url: url)
            w.testing = false
        }
    }
}
