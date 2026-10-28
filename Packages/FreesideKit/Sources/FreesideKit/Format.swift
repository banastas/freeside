import Foundation

public enum Format {
    /// `0.234` → `"23%"`
    public static func percent(_ fraction: Double) -> String {
        "\(Int((max(0, min(1, fraction)) * 100).rounded()))%"
    }

    /// Transfer rate with about three significant figures, decimal units like
    /// Activity Monitor: `"512 B/s"`, `"1.2 KB/s"`, `"12.3 MB/s"`, `"123 MB/s"`.
    public static func rate(_ bytesPerSecond: Double, bits: Bool = false) -> String {
        let units = bits ? ["b", "Kb", "Mb", "Gb", "Tb"] : ["B", "KB", "MB", "GB", "TB"]
        let (number, unit) = scaled(max(0, bits ? bytesPerSecond * 8 : bytesPerSecond), step: 1000, units: units)
        return "\(number) \(unit)/s"
    }

    /// Byte count in binary units, the way Activity Monitor labels memory:
    /// `"512 MB"`, `"8.2 GB"`, `"32.0 GB"`.
    public static func bytes(_ count: UInt64) -> String {
        let (number, unit) = scaled(Double(count), step: 1024, units: ["B", "KB", "MB", "GB", "TB"])
        return "\(number) \(unit)"
    }

    /// Byte count in decimal units, for network totals.
    public static func decimalBytes(_ count: UInt64) -> String {
        let (number, unit) = scaled(Double(count), step: 1000, units: ["B", "KB", "MB", "GB", "TB"])
        return "\(number) \(unit)"
    }

    /// Compact gigabytes for the menu bar: `"12.4G"`.
    public static func gigabytesCompact(_ count: UInt64) -> String {
        oneDecimal(Double(count) / 1_073_741_824) + "G"
    }

    /// `"3d 4h"`, `"4h 12m"`, `"12m"`
    public static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let (days, hours, mins) = (minutes / 1440, (minutes / 60) % 24, minutes % 60)
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    private static func scaled(_ value: Double, step: Double, units: [String]) -> (String, String) {
        var value = value
        var index = 0
        while value >= 999.5, index < units.count - 1 {
            value /= step
            index += 1
        }
        let number = switch value {
        case _ where index == 0: String(Int(value.rounded()))
        case ..<99.95: oneDecimal(value)
        default: String(Int(value.rounded()))
        }
        return (number, units[index])
    }

    /// `"12.3"`. Integer arithmetic: this runs every tick, and
    /// `String(format:)` costs several times more.
    private static func oneDecimal(_ value: Double) -> String {
        let tenths = Int((value * 10).rounded())
        return "\(tenths / 10).\(tenths % 10)"
    }
}

extension String {
    /// Right-aligns the string in a field of `width` characters.
    public func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
