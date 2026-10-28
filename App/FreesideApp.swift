import AppKit
import FreesideKit
import ServiceManagement

@main
@MainActor
enum FreesideApp {
    // NSApplication holds its delegate weakly.
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let volumes = VolumeStore()
    private lazy var drives = DriveMonitor(volumes: volumes)
    private let ejector = Ejector()
    private let preferences = Preferences()
    private lazy var notifier = Notifier(volumes: volumes, drives: drives, preferences: preferences)
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        volumes.start()
        drives.start()
        if Dump.isRequested {
            Dump.run(volumes: volumes, drives: drives)
            return
        }
        notifier.start()
        let statusItem = StatusItemController(volumes: volumes, drives: drives, ejector: ejector, preferences: preferences, notifier: notifier)
        self.statusItem = statusItem
        offerLaunchAtLoginOnce()
        // Once the status item has a window for the popover to anchor to.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [volumes, drives, ejector] in
            if Dump.opensPopover { statusItem.showPopover(settings: Dump.opensSettings) }
            if Dump.printsDiagnostics {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    print(statusItem.diagnosticsReport(), terminator: "")
                    NSApp.terminate(nil)
                }
            }
            if let path = Dump.inspectPath {
                Dump.inspect(path, volumes: volumes, drives: drives, ejector: ejector, show: { statusItem.showPopover(focus: $0) })
            }
        }
    }

    /// Asks once whether to start at login; a menu bar app is most useful
    /// when it's always there. The choice can be changed later in settings.
    private func offerLaunchAtLoginOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "offeredLaunchAtLogin") else { return }

        // A copy running from the DMG (or translocated by Gatekeeper) can't
        // register a login item; ask once it has been moved to Applications.
        let path = Bundle.main.bundlePath
        guard path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/") else { return }

        defaults.set(true, forKey: "offeredLaunchAtLogin")
        guard SMAppService.mainApp.status != .enabled else { return }

        // Let the status item appear first so the question has context.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let alert = NSAlert()
            alert.messageText = "Start freeside when you log in?"
            alert.informativeText = "freeside lives in the menu bar. You can change this any time in its settings."
            alert.addButton(withTitle: "Start at Login")
            alert.addButton(withTitle: "Not Now")
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn {
                try? SMAppService.mainApp.register()
            }
        }
    }
}
