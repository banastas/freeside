import Foundation

/// The plain-text report Copy Diagnostics puts on the clipboard, for pasting
/// into a GitHub issue. Volume names and formats, the volume → device map,
/// recent eject failures and the last scan's cost; never a path from a
/// blocker scan. Nothing is sent anywhere.
public enum Diagnostics {
    public struct Environment: Sendable {
        public var appVersion: String
        public var build: String
        public var osVersion: String
        public var model: String
        /// "style icon, units decimal, …"
        public var settings: [String]

        public init(appVersion: String, build: String, osVersion: String, model: String, settings: [String]) {
            self.appVersion = appVersion
            self.build = build
            self.osVersion = osVersion
            self.model = model
            self.settings = settings
        }

        /// This process: bundle version, macOS version and `hw.model`.
        public static func current(settings: [String]) -> Environment {
            let info = Bundle.main.infoDictionary ?? [:]
            return Environment(
                appVersion: info["CFBundleShortVersionString"] as? String ?? "dev",
                build: info["CFBundleVersion"] as? String ?? "?",
                // "Version 27.2 (Build 26B123)"
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString.replacing("Version ", with: ""),
                model: hardwareModel(),
                settings: settings
            )
        }
    }

    public static func report(
        environment: Environment,
        volumes: [Volume],
        drives: [Drive],
        log: [Ejector.LogEntry],
        lastScan: Ejector.ScanSummary?,
        now: Date = .now
    ) -> String {
        var lines = [
            "freeside \(environment.appVersion) (\(environment.build))",
            "macOS \(environment.osVersion)",
            environment.model,
            "Report time: \(timestamp(now))",
        ]
        if !environment.settings.isEmpty {
            lines.append("Settings: \(environment.settings.joined(separator: ", "))")
        }

        lines.append("")
        lines.append("Drives")
        if drives.isEmpty { lines.append("  none") }
        let byID = Dictionary(volumes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for drive in drives {
            let rates = drive.readRate == nil ? "no I/O statistics" : "I/O statistics"
            lines.append("  \(drive.name) · \(drive.kind.rawValue) · \(drive.deviceProtocol ?? "-") · \(drive.members.map(\.bsdName).joined(separator: "+")) · \(rates)")
            for volume in drive.volumeIDs.compactMap({ byID[$0] }) {
                lines.append("    \(line(for: volume))")
            }
        }

        let onDrives = Set(drives.flatMap(\.volumeIDs))
        let loose = volumes.filter { !onDrives.contains($0.id) }
        if !loose.isEmpty {
            lines.append("")
            lines.append("Volumes without a drive")
            for volume in loose { lines.append("  \(line(for: volume))") }
        }

        lines.append("")
        lines.append("Recent eject failures")
        if log.isEmpty { lines.append("  none") }
        for entry in log {
            lines.append("  \(timestamp(entry.date)) · \(entry.targetName) · \(entry.kind.rawValue) · \(entry.failure.diagnosticDescription)")
        }

        lines.append("")
        lines.append("Last blocker scan")
        if let scan = lastScan {
            let milliseconds = Int((scan.duration.timeInterval * 1000).rounded())
            lines.append("  \(milliseconds) ms · \(scan.processCount) processes · \(scan.blockerCount) holding · \(scan.imageCount) disk images · mapped-file pass \(scan.scannedMappedFiles ? "yes" : "no")")
        } else {
            lines.append("  none")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// "Photography · external · APFS · USB · disk7s1 · 2.5 TB free of 4.0 TB"
    private static func line(for volume: Volume) -> String {
        var parts = [volume.name, volume.kind.rawValue, volume.format, volume.deviceProtocol ?? "-", volume.bsdName ?? "-"]
        if let space = volume.space {
            parts.append("\(space.available) available, \(space.availableStrict) strict, \(space.total) total" + (space.isStale ? ", stale" : ""))
        } else {
            parts.append("space not read")
        }
        if volume.isBoot { parts.append("boot") }
        return parts.joined(separator: " · ")
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .current))
    }

    private static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown Mac" }
        return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}
