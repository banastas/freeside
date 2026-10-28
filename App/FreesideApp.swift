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
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        volumes.start()
        drives.start()
        if Dump.isRequested {
            Dump.run(volumes: volumes, drives: drives)
            return
        }
        statusItem = StatusItemController(volumes: volumes, drives: drives)
    }
}
