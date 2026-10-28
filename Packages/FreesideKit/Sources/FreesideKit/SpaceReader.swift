import Foundation
import Synchronization

/// Reads capacity on a dedicated queue with a timeout. A share whose server
/// has gone away can block a read for minutes; that must stall only the
/// reader thread, never the main actor or Swift's cooperative pool.
public struct SpaceReader: Sendable {
    public var timeout: Duration
    private let readBlocking: @Sendable (String) -> Space?
    private let readQuickBlocking: @Sendable (String) -> Space?

    private static let queue = DispatchQueue(label: "as.banast.freeside.space", qos: .utility, attributes: .concurrent)
    /// Paths whose blocking read hasn't returned yet, timed out or not. A hung
    /// share gets one stuck thread, not a new one every refresh.
    private static let blocked = Mutex<Set<String>>([])

    public init(timeout: Duration = .seconds(2)) {
        self.init(timeout: timeout, readBlocking: Self.readNow, readQuickBlocking: Self.readQuickNow)
    }

    /// For tests: stands in a slow or hanging read.
    init(
        timeout: Duration,
        readBlocking: @escaping @Sendable (String) -> Space?,
        readQuickBlocking: (@Sendable (String) -> Space?)? = nil
    ) {
        self.timeout = timeout
        self.readBlocking = readBlocking
        self.readQuickBlocking = readQuickBlocking ?? readBlocking
    }

    /// Nil when the read failed, timed out, or an earlier read of the same
    /// path is still stuck. A `quick` read skips the Finder-matching figure
    /// (see `readQuickNow`).
    public func read(path: String, quick: Bool = false) async -> Space? {
        let readBlocking = quick ? readQuickBlocking : self.readBlocking
        let started = Self.blocked.withLock { $0.insert(path).inserted }
        guard started else { return nil }
        return await withCheckedContinuation { continuation in
            let resumed = Mutex(false)
            let finish: @Sendable (Space?) -> Void = { space in
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: space) }
            }
            Self.queue.async { [readBlocking] in
                let space = readBlocking(path)
                Self.blocked.withLock { _ = $0.remove(path) }
                finish(space)
            }
            Self.queue.asyncAfter(deadline: .now() + timeout.timeInterval) { finish(nil) }
        }
    }

    /// Blocking read. Only capacity keys and `statfs`: anything that lists or
    /// opens files inside the volume triggers the removable or network volume
    /// privacy prompt, and could make freeside the process holding the drive.
    static func readNow(path: String) -> Space? {
        // A new URL starts with an empty resource-value cache; clearing it
        // as well makes sure a refresh never returns the first value read.
        var url = URL(fileURLWithPath: path, isDirectory: true)
        url.removeAllCachedResourceValues()
        let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])

        var fs = statfs()
        let haveStatfs = statfs(path, &fs) == 0
        let statfsTotal = haveStatfs ? Int64(fs.f_blocks) * Int64(fs.f_bsize) : nil
        let statfsAvailable = haveStatfs ? Int64(fs.f_bavail) * Int64(fs.f_bsize) : nil

        guard let total = values?.volumeTotalCapacity.map(Int64.init) ?? statfsTotal,
              let strict = values?.volumeAvailableCapacity.map(Int64.init) ?? statfsAvailable,
              let available = available(important: values?.volumeAvailableCapacityForImportantUsage, strict: strict)
        else { return nil }
        return Space(total: total, available: available, availableStrict: strict)
    }

    /// Total and plain free space only, for refreshing during a write.
    /// `volumeAvailableCapacityForImportantUsageKey` makes macOS work out
    /// purgeable space: about 11 ms of CPU per read on the boot volume and
    /// 3 ms on an external APFS drive (M9), against 0.2 ms and 9 µs for
    /// these. `available` comes back equal to `availableStrict`; the caller
    /// estimates Finder's figure from the last full read.
    static func readQuickNow(path: String) -> Space? {
        var url = URL(fileURLWithPath: path, isDirectory: true)
        url.removeAllCachedResourceValues()
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        var fs = statfs()
        let haveStatfs = statfs(path, &fs) == 0
        guard let total = values?.volumeTotalCapacity.map(Int64.init) ?? (haveStatfs ? Int64(fs.f_blocks) * Int64(fs.f_bsize) : nil),
              let strict = values?.volumeAvailableCapacity.map(Int64.init) ?? (haveStatfs ? Int64(fs.f_bavail) * Int64(fs.f_bsize) : nil)
        else { return nil }
        return Space(total: total, available: strict, availableStrict: strict)
    }

    /// Finder's figure after a quick read: the last full read's, moved by
    /// however much plain free space has changed since.
    static func estimate(_ quick: Space, from full: Space) -> Space {
        Space(total: quick.total, available: max(0, full.available + quick.availableStrict - full.availableStrict), availableStrict: quick.availableStrict)
    }

    /// Finder's number when the volume reports one. SMB shares report 0
    /// rather than nil, so 0 falls back too.
    static func available(important: Int64?, strict: Int64?) -> Int64? {
        if let important, important > 0 { return important }
        return strict
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
