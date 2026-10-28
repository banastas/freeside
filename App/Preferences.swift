import Foundation
import FreesideKit
import Observation

/// User settings, persisted to `UserDefaults`. The settings panel comes in
/// M6; until then the menu bar ones are in the right-click menu.
@MainActor
@Observable
final class Preferences {
    var menuBarStyle: MenuBarStyle { didSet { save(menuBarStyle.rawValue, "menuBarStyle") } }
    /// Nil: the first external volume, else the boot volume.
    var pinnedVolumeID: String? { didSet { save(pinnedVolumeID, "pinnedVolumeID") } }
    var activityDuringTransfers: Bool { didSet { save(activityDuringTransfers, "activityDuringTransfers") } }
    /// The small read/write graph next to the rates.
    var activityTrace: Bool { didSet { save(activityTrace, "activityTrace") } }
    var units: ByteUnits { didSet { save(units.rawValue, "units") } }
    var lowSpaceThreshold: LowSpaceThreshold { didSet { save(lowSpaceThreshold.rawValue, "lowSpaceThreshold") } }
    var volumesShown: Set<VolumeKind> { didSet { save(volumesShown.map(\.rawValue).sorted(), "volumesShown") } }
    var hideWhenNoExternal: Bool { didSet { save(hideWhenNoExternal, "hideWhenNoExternal") } }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "activityDuringTransfers": true,
            "activityTrace": true,
            "volumesShown": [VolumeKind.external, .diskImage, .internal].map(\.rawValue),
        ])
        menuBarStyle = Self.load(defaults, "menuBarStyle", .icon)
        pinnedVolumeID = defaults.string(forKey: "pinnedVolumeID")
        activityDuringTransfers = defaults.bool(forKey: "activityDuringTransfers")
        activityTrace = defaults.bool(forKey: "activityTrace")
        units = Self.load(defaults, "units", .decimal)
        lowSpaceThreshold = defaults.string(forKey: "lowSpaceThreshold").flatMap(LowSpaceThreshold.init(rawValue:)) ?? .percent(10)
        volumesShown = Set((defaults.stringArray(forKey: "volumesShown") ?? []).compactMap(VolumeKind.init(rawValue:)))
        hideWhenNoExternal = defaults.bool(forKey: "hideWhenNoExternal")
    }

    /// The pinned volume if it's mounted, else nil; the default when none is chosen.
    func pinnedVolume(in volumes: [Volume]) -> Volume? {
        guard let pinnedVolumeID else { return Volume.defaultPinned(in: volumes) }
        return volumes.first { $0.id == pinnedVolumeID }
    }

    private func save(_ value: (some Sendable)?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    private static func load<T: RawRepresentable<String>>(_ defaults: UserDefaults, _ key: String, _ fallback: T) -> T {
        guard let raw = defaults.string(forKey: key), let value = T(rawValue: raw) else { return fallback }
        return value
    }
}
