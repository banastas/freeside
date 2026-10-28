import AppKit
import FreesideKit

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
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        volumes.start()
        drives.start()
        if Dump.isRequested {
            Dump.run(volumes: volumes, drives: drives)
            return
        }
        let statusItem = StatusItemController(volumes: volumes, drives: drives, ejector: ejector, preferences: preferences)
        self.statusItem = statusItem
        // Once the status item has a window for the popover to anchor to.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [volumes, drives, ejector] in
            if Dump.opensPopover { statusItem.showPopover() }
            if let path = Dump.inspectPath {
                Dump.inspect(path, volumes: volumes, drives: drives, ejector: ejector, show: { statusItem.showPopover(focus: $0) })
            }
        }
    }
}
