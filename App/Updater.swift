import AppKit
import Observation
import Sparkle

/// Sparkle updates from https://freeside.banast.as/appcast.xml (see
/// Info.plist), as in flatline. Also remembers a found update for the
/// popover's footer.
@MainActor
@Observable
final class Updater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// The newer version a check found, until it's installed or a later
    /// check finds none.
    private(set) var availableVersion: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    func checkForUpdates() {
        // freeside has no Dock icon; activate so Sparkle's window comes to the front.
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in self.availableVersion = version }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in self.availableVersion = nil }
    }

    // MARK: - SPUStandardUserDriverDelegate

    // Background apps opt in to gentle reminders; without this Sparkle warns
    // that a scheduled update alert may go unnoticed behind other apps.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // A scheduled check found an update: bring the alert forward.
        if handleShowingUpdate && !state.userInitiated {
            DispatchQueue.main.async { NSApp.activate() }
        }
    }
}
