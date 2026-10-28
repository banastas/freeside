import Foundation

extension LowSpaceThreshold {
    /// The free space below which a volume is low.
    public func bytes(total: Int64) -> Double {
        switch self {
        case .percent(let value): Double(total) * Double(value) / 100
        case .gigabytes(let value): Double(value) * 1_000_000_000
        }
    }

    /// Back above the threshold with a margin, so a volume hovering around it
    /// doesn't notify on every write and delete.
    public func isClear(_ space: Space) -> Bool {
        guard space.total > 0 else { return true }
        return Double(space.available) >= bytes(total: space.total) * LowSpaceWatch.hysteresis
    }
}

/// Finds volumes that have just crossed the low-space threshold, once per
/// crossing. A volume that is already low when it's first seen (at launch,
/// on mount, or after the threshold changes) isn't a crossing.
public struct LowSpaceWatch: Sendable {
    /// A low volume is re-armed once its free space is 10 % above the threshold.
    public static let hysteresis = 1.1

    private var low: [Volume.ID: Bool] = [:]
    private var threshold: LowSpaceThreshold?

    public init() {}

    /// Returns the volumes that crossed since the last update.
    public mutating func update(_ volumes: [Volume], threshold: LowSpaceThreshold) -> [Volume] {
        if threshold != self.threshold {
            self.threshold = threshold
            low = [:]
        }
        var crossed: [Volume] = []
        var next: [Volume.ID: Bool] = [:]
        for volume in volumes {
            // A stale value says nothing new.
            guard let space = volume.space, !space.isStale else {
                next[volume.id] = low[volume.id]
                continue
            }
            let was = low[volume.id]
            let isLow = was == true ? !threshold.isClear(space) : threshold.isLow(space)
            if was == false, isLow { crossed.append(volume) }
            next[volume.id] = isLow
        }
        low = next
        return crossed
    }
}

/// A finished write to one drive, for the Transfer finished notification.
public struct FinishedTransfer: Sendable, Equatable {
    public var bytes: UInt64
    public var duration: Duration
}

/// One drive's writes, from the rate first going over 1 MB/s until it has
/// stayed below for 10 s. Reports the transfer if it wrote at least 1 GB.
public struct WriteSession: Sendable {
    public static let threshold = DriveMonitor.transferThreshold
    public static let minimumBytes: UInt64 = 1_000_000_000
    public static let endAfter: Duration = .seconds(10)

    public private(set) var bytes: UInt64 = 0
    private var startedAt: ContinuousClock.Instant?
    private var belowSince: ContinuousClock.Instant?

    public init() {}

    /// While open, the 5 s check keeps running with the display asleep, so
    /// the end is seen.
    public var isOpen: Bool { startedAt != nil }

    public mutating func update(writeRate: Double, written: UInt64, at now: ContinuousClock.Instant) -> FinishedTransfer? {
        if writeRate > Self.threshold {
            if startedAt == nil { startedAt = now }
            belowSince = nil
            bytes &+= written
            return nil
        }
        guard let startedAt else { return nil }
        bytes &+= written
        if belowSince == nil { belowSince = now }
        guard let belowSince, now - belowSince >= Self.endAfter else { return nil }
        let finished = FinishedTransfer(bytes: bytes, duration: belowSince - startedAt)
        self = WriteSession()
        return finished.bytes >= Self.minimumBytes ? finished : nil
    }
}
