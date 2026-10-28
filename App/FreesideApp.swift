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
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        volumes.start()
        if VolumeDump.isRequested {
            VolumeDump.run(volumes)
            return
        }
        statusItem = StatusItemController(volumes: volumes)
    }
}
