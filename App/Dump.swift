import AppKit
import FreesideKit

/// Development hooks for checking numbers without a screen:
///
/// - `FREESIDE_DUMP_VOLUMES=1` prints every volume with exact byte counts
///   and quits, for comparing with Finder and `df`.
/// - `FREESIDE_DUMP_RATES=<seconds>` samples every second for that long,
///   printing each drive's read and write bytes per second, for comparing
///   with `iostat`.
/// - `FREESIDE_INSPECT=<mount path>` opens the popover on the drive holding
///   that volume and runs "Who's using this?", printing the scan.
///   `FREESIDE_EJECT=<mount path>` ejects that drive instead, opening the
///   popover if the eject fails.
/// - `FREESIDE_POPOVER=1` opens the popover at launch; `=internal` also
///   expands the internal disk.
@MainActor
enum Dump {
    private static let environment = ProcessInfo.processInfo.environment

    static var isRequested: Bool {
        environment["FREESIDE_DUMP_VOLUMES"] != nil || environment["FREESIDE_DUMP_RATES"] != nil
    }

    /// A hook opened the popover; it stays open until closed in code.
    static var isHooked: Bool { opensPopover || inspectPath != nil }

    static var opensPopover: Bool { environment["FREESIDE_POPOVER"] != nil }
    static var expandsInternal: Bool { environment["FREESIDE_POPOVER"] == "internal" }

    static var inspectPath: String? { environment["FREESIDE_INSPECT"] ?? environment["FREESIDE_EJECT"] }

    static func inspect(_ path: String, volumes: VolumeStore, drives: DriveMonitor, ejector: Ejector, show: @escaping (EjectTarget.ID) -> Void) {
        let eject = environment["FREESIDE_EJECT"] != nil
        Task {
            while !drives.drives.contains(where: { drive in drive.volumeIDs.contains { id in volumes.volumes.first { $0.id == id }?.mountPath == path } }) {
                try? await Task.sleep(for: .milliseconds(50))
            }
            let id = volumes.volumes.first { $0.mountPath == path }!.id
            let target = EjectTarget(drive: drives.drives.first { $0.volumeIDs.contains(id) }!)
            if eject {
                let ejected = await ejector.eject(target)
                print("ejected:", ejected, ejector.statuses[target.id]?.failure.map(String.init(describing:)) ?? "-")
                if !ejected { show(target.id) }
            } else {
                show(target.id)
                await ejector.inspect(target)
            }
            let report = ejector.statuses[target.id]?.report
            print("scan:", report?.processCount ?? 0, "processes,", report?.duration ?? .zero)
            for blocker in report?.blockers ?? [] {
                print(blocker.pid, blocker.processName, blocker.app?.name ?? "-", blocker.isAppProcess, blocker.uses.map { "\($0.reason.rawValue) \($0.path)" })
            }
            for image in report?.images ?? [] { print("image", image.bsdName, image.imagePath) }
            fflush(stdout)
        }
    }

    static func run(volumes: VolumeStore, drives: DriveMonitor) {
        if let seconds = environment["FREESIDE_DUMP_RATES"].flatMap(Int.init) {
            rates(drives, for: seconds)
        } else {
            self.volumes(volumes)
        }
    }

    private static func volumes(_ store: VolumeStore) {
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

    private static func rates(_ monitor: DriveMonitor, for seconds: Int) {
        let start = Date()
        print(["time", "drive", "disks", "kind", "read", "write"].joined(separator: "\t"))
        monitor.onSample = {
            let time = String(format: "%.1f", Date().timeIntervalSince(start))
            for drive in monitor.drives {
                print([
                    time, drive.name, drive.members.map(\.bsdName).joined(separator: "+"), drive.kind.rawValue,
                    drive.readRate.map { String(Int($0)) } ?? "-",
                    drive.writeRate.map { String(Int($0)) } ?? "-",
                ].joined(separator: "\t"))
            }
            print([time, "external total", "-", "-", String(Int(monitor.externalReadRate)), String(Int(monitor.externalWriteRate))].joined(separator: "\t"))
            fflush(stdout)
            if Date().timeIntervalSince(start) >= Double(seconds) { NSApp.terminate(nil) }
        }
        monitor.setDetailed(true)
    }
}
