import AppKit
import FreesideKit

/// `FREESIDE_DUMP_VOLUMES=1` prints every volume with exact byte counts and
/// quits, for checking against Finder and `diskutil` without a screen.
@MainActor
enum VolumeDump {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["FREESIDE_DUMP_VOLUMES"] != nil
    }

    static func run(_ store: VolumeStore) {
        Task {
            // Give the first reads a moment; a timed-out share prints as stale.
            let clock = ContinuousClock()
            let start = clock.now
            while store.volumes.contains(where: { $0.space == nil }), clock.now - start < .seconds(3) {
                try? await Task.sleep(for: .milliseconds(50))
            }
            print(["name", "kind", "format", "protocol", "total", "available", "strict", "stale", "path"].joined(separator: "\t"))
            for volume in store.volumes {
                let space = volume.space
                print([
                    volume.name, volume.kind.rawValue, volume.format, volume.deviceProtocol ?? "-",
                    space.map { String($0.total) } ?? "-",
                    space.map { String($0.available) } ?? "-",
                    space.map { String($0.availableStrict) } ?? "-",
                    space.map { String($0.isStale) } ?? "-",
                    volume.mountPath,
                ].joined(separator: "\t"))
            }
            NSApp.terminate(nil)
        }
    }
}
