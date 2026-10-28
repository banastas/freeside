import FreesideKit
import Observation
import SwiftUI

/// The popover's accent, shared with flatline.
enum Accent: String, CaseIterable, Identifiable {
    case phosphor, cyan, magenta, amber, system
    var id: Self { self }

    var label: String {
        switch self {
        case .phosphor: "Phosphor Green"
        case .cyan: "Cyan"
        case .magenta: "Magenta"
        case .amber: "Amber"
        case .system: "System"
        }
    }

    var color: Color {
        switch self {
        case .phosphor: Color(red: 0.20, green: 0.95, blue: 0.45)
        case .cyan: Color(red: 0.15, green: 0.85, blue: 1.00)
        case .magenta: Color(red: 1.00, green: 0.25, blue: 0.75)
        case .amber: Color(red: 1.00, green: 0.72, blue: 0.10)
        case .system: .accentColor
        }
    }

    /// For writes, mirrored below reads in a trace.
    var writeColor: Color {
        self == .magenta ? Accent.cyan.color : Accent.magenta.color
    }
}

/// User settings, persisted to `UserDefaults` and shown in the popover's
/// settings panel.
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
    var accent: Accent { didSet { save(accent.rawValue, "accent") } }
    var notifyLowSpace: Bool { didSet { save(notifyLowSpace, "notifyLowSpace") } }
    var notifyTransferFinished: Bool { didSet { save(notifyTransferFinished, "notifyTransferFinished") } }

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
        accent = Self.load(defaults, "accent", .phosphor)
        notifyLowSpace = defaults.bool(forKey: "notifyLowSpace")
        notifyTransferFinished = defaults.bool(forKey: "notifyTransferFinished")
    }

    /// The pinned volume if it's mounted, else nil; the default when none is chosen.
    func pinnedVolume(in volumes: [Volume]) -> Volume? {
        guard let pinnedVolumeID else { return Volume.defaultPinned(in: volumes) }
        return volumes.first { $0.id == pinnedVolumeID }
    }

    /// For Copy Diagnostics; names no volume.
    var summary: [String] {
        [
            "style \(menuBarStyle.rawValue)",
            "pinned \(pinnedVolumeID == nil ? "automatic" : "chosen")",
            "activity during transfers \(activityDuringTransfers ? "on" : "off")",
            "trace \(activityTrace ? "on" : "off")",
            "units \(units.rawValue)",
            "low space \(lowSpaceThreshold.rawValue)",
            "shown \(VolumeKind.allCases.filter(volumesShown.contains).map(\.rawValue).joined(separator: "+"))",
            "hide without external \(hideWhenNoExternal ? "on" : "off")",
            "notify low space \(notifyLowSpace ? "on" : "off")",
            "notify transfer finished \(notifyTransferFinished ? "on" : "off")",
        ]
    }

    private func save(_ value: (some Sendable)?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    private static func load<T: RawRepresentable<String>>(_ defaults: UserDefaults, _ key: String, _ fallback: T) -> T {
        guard let raw = defaults.string(forKey: key), let value = T(rawValue: raw) else { return fallback }
        return value
    }
}
