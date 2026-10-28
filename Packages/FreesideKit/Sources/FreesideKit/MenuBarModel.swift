import Foundation

/// What the status item shows.
public enum MenuBarStyle: String, Sendable, CaseIterable, Identifiable {
    case icon
    case space
    case activity
    case spaceActivity

    public var id: Self { self }

    public var label: String {
        switch self {
        case .icon: "Icon"
        case .space: "Space"
        case .activity: "Activity"
        case .spaceActivity: "Space and Activity"
        }
    }

    public var showsSpace: Bool { self == .space || self == .spaceActivity }
    public var showsActivity: Bool { self == .activity || self == .spaceActivity }

    /// What to draw now. `icon` and `space` switch to `activity` during a
    /// transfer (when that's on); without its pinned volume, `space` falls
    /// back to `icon` and `space+activity` to `activity`.
    public func effective(pinnedMounted: Bool, transferring: Bool, activityDuringTransfers: Bool) -> MenuBarStyle {
        if transferring, activityDuringTransfers, self == .icon || self == .space { return .activity }
        guard !pinnedMounted else { return self }
        return switch self {
        case .space: .icon
        case .spaceActivity: .activity
        default: self
        }
    }

    /// Every style `effective` can return, so the item's width can be
    /// reserved for all of them and nothing moves when it switches.
    public func reserved(activityDuringTransfers: Bool) -> [MenuBarStyle] {
        var styles = [self]
        if showsSpace { styles.append(self == .space ? .icon : .activity) }
        if activityDuringTransfers, self == .icon || self == .space { styles.append(.activity) }
        return styles
    }
}

/// Byte units for space and rates.
public enum ByteUnits: String, Sendable, CaseIterable, Identifiable {
    /// GB and MB/s, like Finder.
    case decimal
    /// GiB and MiB/s.
    case binary

    public var id: Self { self }
    public var label: String { self == .decimal ? "Decimal (GB)" : "Binary (GiB)" }
    var step: Double { self == .decimal ? 1000 : 1024 }
    var names: [String] { self == .decimal ? ["B", "KB", "MB", "GB", "TB", "PB"] : ["B", "KiB", "MiB", "GiB", "TiB", "PiB"] }
}

/// Below this, a volume gets the low-space mark.
public enum LowSpaceThreshold: Sendable, Hashable, RawRepresentable, Identifiable {
    case percent(Int)
    case gigabytes(Int)

    public static let presets: [LowSpaceThreshold] = [.percent(5), .percent(10), .percent(20)]

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ":")
        guard parts.count == 2, let value = Int(parts[1]), value > 0 else { return nil }
        switch parts[0] {
        case "percent": self = .percent(min(value, 100))
        case "gigabytes": self = .gigabytes(value)
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .percent(let value): "percent:\(value)"
        case .gigabytes(let value): "gigabytes:\(value)"
        }
    }

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .percent(let value): "\(value) %"
        case .gigabytes(let value): "\(value) GB"
        }
    }

    /// Uses `available`, the number Finder shows, so the mark agrees with it.
    public func isLow(_ space: Space) -> Bool {
        guard space.total > 0 else { return false }
        return switch self {
        case .percent(let value): Double(space.available) < Double(space.total) * Double(value) / 100
        case .gigabytes(let value): space.available < Int64(value) * 1_000_000_000
        }
    }
}

/// A transfer is running once the combined external rate has stayed over
/// 1 MB/s for 3 s, and has ended 10 s after it last dropped below.
public struct TransferDetector: Sendable {
    public static let threshold = DriveMonitor.transferThreshold
    public static let startAfter: Duration = .seconds(3)
    public static let endAfter: Duration = .seconds(10)

    public private(set) var isActive = false
    private var aboveSince: ContinuousClock.Instant?
    private var belowSince: ContinuousClock.Instant?

    public init() {}

    /// Over the threshold but not yet for long enough: worth sampling every
    /// second to find out.
    public var isPending: Bool { !isActive && aboveSince != nil }

    /// Returns true when `isActive` or `isPending` changed.
    @discardableResult
    public mutating func update(rate: Double, at now: ContinuousClock.Instant) -> Bool {
        let before = (isActive, isPending)
        if rate > Self.threshold {
            belowSince = nil
            if aboveSince == nil { aboveSince = now }
            if let aboveSince, now - aboveSince >= Self.startAfter { isActive = true }
        } else {
            aboveSince = nil
            if isActive {
                if belowSince == nil { belowSince = now }
                if let belowSince, now - belowSince >= Self.endAfter {
                    isActive = false
                    self.belowSince = nil
                }
            }
        }
        return before != (isActive, isPending)
    }
}

extension Volume {
    /// The `space` style's default: the first external volume, else the boot volume.
    public static func defaultPinned(in volumes: [Volume]) -> Volume? {
        volumes.first { $0.kind == .external } ?? volumes.first { $0.isBoot }
    }
}

extension Format {
    /// Four characters at most, for the menu bar: `"1.2T"`, `"856G"`, `"12M"`,
    /// `"512B"`, `"0"`.
    public static func compact(_ bytes: Double, units: ByteUnits = .decimal) -> String {
        guard bytes >= 0.5 else { return "0" }
        let suffixes = ["B", "K", "M", "G", "T", "P"]
        var value = bytes
        var index = 0
        while value >= 999.5, index < suffixes.count - 1 {
            value /= units.step
            index += 1
        }
        let number = index > 0 && value < 9.95 ? oneDecimalString(value) : String(Int(value.rounded()))
        return number + suffixes[index]
    }

    /// For VoiceOver: `"1.2 terabytes"`, `"380 megabytes per second"`.
    public static func spoken(bytes: Double, units: ByteUnits = .decimal, perSecond: Bool = false) -> String {
        let names = ["bytes", "kilobytes", "megabytes", "gigabytes", "terabytes", "petabytes"]
        var value = max(0, bytes)
        var index = 0
        while value >= 999.5, index < names.count - 1 {
            value /= units.step
            index += 1
        }
        let number = index > 0 && value < 99.95 ? oneDecimalString(value) : String(Int(value.rounded()))
        return "\(number) \(names[index])" + (perSecond ? " per second" : "")
    }

    private static func oneDecimalString(_ value: Double) -> String {
        let tenths = Int((value * 10).rounded())
        return "\(tenths / 10).\(tenths % 10)"
    }
}
