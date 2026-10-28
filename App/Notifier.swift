import AppKit
import FreesideKit
import Observation
import UserNotifications

/// Low space and Transfer finished (PRD §6.5). Both are off by default;
/// turning one on asks for permission. The low-space watch runs either way,
/// so turning it on doesn't announce volumes that were already low.
@MainActor
@Observable
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    @ObservationIgnored private let volumes: VolumeStore
    @ObservationIgnored private let drives: DriveMonitor
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var lowSpace = LowSpaceWatch()
    @ObservationIgnored private var center: UNUserNotificationCenter { .current() }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=as.banast.freeside")!

    init(volumes: VolumeStore, drives: DriveMonitor, preferences: Preferences) {
        self.volumes = volumes
        self.drives = drives
        self.preferences = preferences
    }

    func start() {
        center.delegate = self
        drives.onTransferFinished = { [weak self] drive, finished in self?.transferFinished(drive, finished) }
        observeVolumes()
        Task { await refreshAuthorization() }
    }

    var isDenied: Bool { authorization == .denied }

    /// When a notification setting is turned on. Asks only the first time;
    /// after that it reads what System Settings says.
    func requestAuthorization() async {
        await refreshAuthorization()
        guard authorization == .notDetermined else { return }
        NSApp.activate()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        await refreshAuthorization()
    }

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    // MARK: - Low space

    private func observeVolumes() {
        withObservationTracking {
            checkLowSpace()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeVolumes() }
        }
    }

    private func checkLowSpace() {
        let shown = volumes.volumes.filter { preferences.volumesShown.contains($0.kind) }
        let threshold = preferences.lowSpaceThreshold
        let crossed = lowSpace.update(shown, threshold: threshold)
        guard preferences.notifyLowSpace else { return }
        for volume in crossed {
            guard let space = volume.space else { continue }
            let units = preferences.units
            post(
                id: "low-space-\(volume.id)",
                title: "\(volume.name) is low on space",
                body: "\(Format.size(space.available, units: units)) free of \(Format.size(space.total, units: units)), below \(threshold.label).",
                sound: false
            )
        }
    }

    // MARK: - Transfer finished

    private func transferFinished(_ drive: Drive, _ finished: FinishedTransfer) {
        guard preferences.notifyTransferFinished else { return }
        let size = Format.size(Int64(clamping: finished.bytes), units: preferences.units)
        let time = finished.duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
        post(
            id: "transfer-\(drive.id)-\(Date.now.timeIntervalSince1970)",
            title: "Finished writing to \(drive.name)",
            body: "\(size) in \(time).",
            sound: true
        )
    }

    private func post(id: String, title: String, body: String, sound: Bool) {
        if Dump.logsNotifications {
            print("notification:", title, "|", body, "| authorization", authorization.rawValue)
            fflush(stdout)
        }
        guard authorization == .authorized || authorization == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Shown even while freeside is the active app (the popover is open).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
