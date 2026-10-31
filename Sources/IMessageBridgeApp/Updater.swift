import AppKit
import Combine
import Sparkle

/// Auto-updates with Sparkle, from the appcast attached to the latest GitHub
/// release (SUFeedURL in Info.plist). Updates are checked daily and downloaded
/// in the background. Sparkle would install them on quit, but a menu bar app is
/// rarely quit, so the update is installed (and the app relaunched) once no
/// agent has used the bridge for a while and nothing is waiting on the user.
@MainActor
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    /// How long the bridge must be unused before an update relaunches it.
    static let idleBeforeInstall: TimeInterval = 10 * 60

    @Published private(set) var canCheck = false
    @Published private(set) var readyVersion: String?
    private var controller: SPUStandardUpdaterController?
    private var installNow: (() -> Void)?
    private var timer: Timer?
    private var observation: AnyCancellable?

    /// False when running outside a signed .app (swift run, tests, screenshots).
    var isAvailable: Bool { controller != nil }

    var automaticallyInstalls: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set {
            guard let updater = controller?.updater else { return }
            objectWillChange.send()
            if newValue { updater.automaticallyChecksForUpdates = true }
            updater.automaticallyDownloadsUpdates = newValue
        }
    }

    func start() {
        guard controller == nil, Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        controller = c
        observation = c.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheck = $0 }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    private func scheduleInstall(version: String, _ install: @escaping () -> Void) {
        readyVersion = version
        installNow = install
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in Updater.shared.installIfIdle() }
        }
    }

    private func installIfIdle() {
        guard let install = installNow else { return }
        let state = AppState.shared
        let lastUse = ([state.activity.first?.date] + state.agents.map(\.lastUsedAt)).compactMap { $0 }.max() ?? .distantPast
        guard Date().timeIntervalSince(lastUse) >= Self.idleBeforeInstall,
              !state.pairings.contains(where: \.isPending),
              !Messaging.isConfirming else { return }
        timer?.invalidate()
        timer = nil
        installNow = nil
        state.log(agent: "iMessage Bridge", action: "update", detail: "installing \(readyVersion ?? "an update") and relaunching", ok: true)
        install()
    }
}

extension Updater: SPUUpdaterDelegate {
    /// Sparkle hands over an update it would otherwise install at quit.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            scheduleInstall(version: version, immediateInstallHandler)
        }
        return true
    }
}
