import Foundation

/// In popover order.
public enum VolumeKind: String, Sendable, CaseIterable, Comparable {
    case external
    case diskImage
    case network
    case `internal`

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// A mounted volume as the popover shows it.
public struct Volume: Identifiable, Sendable, Equatable {
    /// The volume UUID when there is one, so a rename keeps the identity;
    /// otherwise the mount source (BSD name or network URL).
    public let id: String
    public var name: String
    public var mountPath: String
    /// `disk7s1`; nil for network volumes.
    public var bsdName: String?
    public var kind: VolumeKind
    /// Short format name: "APFS", "HFS+", "ExFAT", "SMB".
    public var format: String
    /// DiskArbitration's device protocol: "USB", "Thunderbolt", "Secure Digital".
    public var deviceProtocol: String?
    public var deviceModel: String?
    public var isBoot: Bool
    /// Nil until the first read finishes.
    public var space: Space?
}

public struct Space: Sendable, Equatable {
    public var total: Int64
    /// The number Finder shows: on APFS it includes purgeable space.
    public var available: Int64
    /// Space free right now, without purging anything.
    public var availableStrict: Int64
    /// The last read timed out; these are the values from the read before it.
    public var isStale = false

    public init(total: Int64, available: Int64, availableStrict: Int64, isStale: Bool = false) {
        self.total = total
        self.available = available
        self.availableStrict = availableStrict
        self.isStale = isStale
    }

    public var used: Int64 { max(0, total - available) }

    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

/// What DiskArbitration and the mount table say about a volume, before classification.
struct VolumeFacts: Equatable {
    var isLocal: Bool
    var isRoot: Bool
    var deviceModel: String?
    var deviceInternal: Bool?
    var mediaRemovable: Bool?
}

extension VolumeKind {
    /// External means the device isn't internal, or its media is removable.
    /// The URL keys can't decide this: fixed USB drives report themselves as
    /// neither ejectable nor removable. Removable media covers cards in a
    /// built-in SD slot, which may sit on an internal device.
    init(_ facts: VolumeFacts) {
        if !facts.isLocal {
            self = .network
        } else if facts.deviceModel == "Disk Image" {
            self = .diskImage
        } else if facts.isRoot {
            self = .internal
        } else if facts.deviceInternal == false || facts.mediaRemovable == true {
            self = .external
        } else {
            self = .internal
        }
    }
}

enum FormatName {
    /// Short name from the mount table's file system type.
    static func from(fileSystemType type: String) -> String {
        switch type {
        case "apfs": "APFS"
        case "hfs": "HFS+"
        case "exfat": "ExFAT"
        case "msdos": "FAT"
        case "ntfs": "NTFS"
        case "smbfs": "SMB"
        case "nfs": "NFS"
        case "afpfs": "AFP"
        case "webdav": "WebDAV"
        default: type.uppercased()
        }
    }
}
