import Foundation
import IOKit

/// A physical block device: the `IOBlockStorageDriver` whose statistics
/// count the device's I/O, and the whole disk it publishes.
public struct BlockDevice: Sendable, Hashable, Comparable {
    /// The driver's registry entry ID.
    public let driverID: UInt64
    /// The whole disk under the driver: "disk6".
    public let bsdName: String

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.driverID < rhs.driverID }
}

/// From IOKit/storage headers, which Swift doesn't import.
private enum StorageKey {
    static let blockStorageDriverClass = "IOBlockStorageDriver"
    static let mediaClass = "IOMedia"
    static let whole = "Whole"
    static let statistics = "Statistics"
    static let bytesRead = "Bytes (Read)"
    static let bytesWritten = "Bytes (Write)"
}

enum DeviceMap {
    /// The physical devices a volume lives on. Walks every parent in the
    /// IOService plane, so an APFS volume reaches the disk under its
    /// container, and an AppleRAID set reaches each member disk.
    static func devices(forBSDName bsdName: String) -> [BlockDevice] {
        let media = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsdName))
        guard media != 0 else { return [] }
        defer { IOObjectRelease(media) }
        var found: Set<BlockDevice> = []
        var visited: Set<UInt64> = []
        walk(media, lastWholeDisk: nil, found: &found, visited: &visited)
        return found.sorted()
    }

    private static func walk(_ entry: io_registry_entry_t, lastWholeDisk: String?, found: inout Set<BlockDevice>, visited: inout Set<UInt64>) {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &id)
        guard visited.insert(id).inserted, visited.count < 64 else { return }

        if IOObjectConformsTo(entry, StorageKey.blockStorageDriverClass) != 0 {
            if let lastWholeDisk { found.insert(BlockDevice(driverID: id, bsdName: lastWholeDisk)) }
            return
        }
        var wholeDisk = lastWholeDisk
        if IOObjectConformsTo(entry, StorageKey.mediaClass) != 0, property(entry, StorageKey.whole) as? Bool == true {
            wholeDisk = property(entry, kIOBSDNameKey) as? String
        }

        var parents: io_iterator_t = 0
        guard IORegistryEntryGetParentIterator(entry, kIOServicePlane, &parents) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(parents) }
        while case let parent = IOIteratorNext(parents), parent != 0 {
            walk(parent, lastWholeDisk: wholeDisk, found: &found, visited: &visited)
            IOObjectRelease(parent)
        }
    }

    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

public struct IOCounters: Sendable, Equatable {
    public var bytesRead: UInt64
    public var bytesWritten: UInt64

    public init(bytesRead: UInt64, bytesWritten: UInt64) {
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        IOCounters(bytesRead: lhs.bytesRead &+ rhs.bytesRead, bytesWritten: lhs.bytesWritten &+ rhs.bytesWritten)
    }

    /// Bytes moved since `earlier`. A counter that went backwards (the
    /// driver restarted) counts as zero rather than wrapping.
    public func since(_ earlier: Self) -> Self {
        IOCounters(
            bytesRead: bytesRead >= earlier.bytesRead ? bytesRead - earlier.bytesRead : 0,
            bytesWritten: bytesWritten >= earlier.bytesWritten ? bytesWritten - earlier.bytesWritten : 0
        )
    }
}

/// Holds a block storage driver and reads its `Statistics` dictionary: the
/// same counters `iostat` reads.
final class BlockDriver {
    let device: BlockDevice
    private let entry: io_registry_entry_t

    init?(_ device: BlockDevice) {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(device.driverID))
        guard entry != 0 else { return nil }
        self.device = device
        self.entry = entry
    }

    deinit { IOObjectRelease(entry) }

    /// Nil when the driver publishes no statistics (some USB bridges).
    func counters() -> IOCounters? {
        guard let statistics = DeviceMap.property(entry, StorageKey.statistics) as? [String: Any],
              let read = (statistics[StorageKey.bytesRead] as? NSNumber)?.uint64Value,
              let written = (statistics[StorageKey.bytesWritten] as? NSNumber)?.uint64Value
        else { return nil }
        return IOCounters(bytesRead: read, bytesWritten: written)
    }
}
