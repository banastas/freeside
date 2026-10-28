import AppKit
import FreesideKit
import SwiftUI
import UniformTypeIdentifiers

/// Shared card chrome, as in flatline.
struct Card<Content: View>: View {
    /// An eject that failed or is being looked into.
    var highlighted = false
    @ViewBuilder var content: Content
    @Environment(\.accent) private var accent
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quinary, in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(highlighted ? Color.orange.opacity(0.6) : accent.opacity(contrast == .increased ? 0.5 : 0.18))
        )
    }
}

/// One physical device (or AppleRAID set): rates with a 60 s trace, session
/// totals, Eject, and its volumes. A failed eject or "Who's using this?"
/// shows its blockers inline.
struct DriveCard: View {
    let drive: Drive
    let volumes: [Volume]
    let ejector: Ejector
    let preferences: Preferences
    /// False for the boot drive.
    let ejectable: Bool
    @Environment(\.accent) private var accent
    @Environment(\.writeColor) private var writeColor

    private var target: EjectTarget { EjectTarget(drive: drive) }
    private var status: Ejector.Status? { ejector.statuses[target.id] }

    /// "USB · 2 volumes"
    private var subtitle: String {
        let interface = drive.kind == .internal ? "Internal" : drive.kind == .diskImage ? "Disk image" : drive.deviceProtocol
        var parts = [interface].compactMap(\.self)
        if drive.members.count > 1 { parts.append("RAID of \(drive.members.count)") }
        parts.append(volumes.count == 1 ? "1 volume" : "\(volumes.count) volumes")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Card(highlighted: status?.failure != nil) {
            header
            if let status, status.phase == .ejecting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Ejecting…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if status != nil {
                BlockersView(ejector: ejector, targetID: target.id)
            }
            rates
            if !volumes.isEmpty {
                Divider()
                ForEach(volumes) { volume in
                    VolumeRow(volume: volume, preferences: preferences)
                        .contextMenu { if ejectable { actions } }
                }
            }
        }
        .id(target.id)
    }

    private var header: some View {
        HStack(spacing: 8) {
            DriveIcon(drive: drive)
            VStack(alignment: .leading, spacing: 1) {
                Text(drive.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(drive.name)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if ejectable {
                // A SwiftUI Menu here cost about 4 ms per card on every
                // opening (PRD §8); this builds its menu only when clicked.
                Button {
                    ActionMenu.show([
                        ("Eject", { Task { await ejector.eject(target) } }),
                        ("Who's Using This?", { Task { await ejector.inspect(target) } }),
                    ])
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("More for \(drive.name)")
                Button {
                    Task { await ejector.eject(target) }
                } label: {
                    Label("eject", systemImage: "eject")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(status.map { $0.phase != .idle } ?? false)
                .accessibilityLabel("Eject \(drive.name)")
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Eject") { Task { await ejector.eject(target) } }
        Button("Who's Using This?") { Task { await ejector.inspect(target) } }
    }

    @ViewBuilder
    private var rates: some View {
        if let read = drive.readRate, let write = drive.writeRate {
            let reads = drive.readTrace.elements
            let writes = drive.writeTrace.elements
            let peak = max(1_000_000, reads.max() ?? 0, writes.max() ?? 0)
            HStack {
                Rate(label: "R", value: Format.rate(read, units: preferences.units), color: accent)
                    .accessibilityLabel("Reading \(Format.spoken(bytes: read, units: preferences.units, perSecond: true))")
                Spacer()
                Rate(label: "W", value: Format.rate(write, units: preferences.units), color: writeColor)
                    .accessibilityLabel("Writing \(Format.spoken(bytes: write, units: preferences.units, perSecond: true))")
            }
            TraceView(values: reads, scale: peak, color: accent, mirror: writes, mirrorColor: writeColor)
                .frame(height: 40)
            HStack(spacing: 8) {
                Text("session").foregroundStyle(.secondary)
                Text("R \(Format.size(Int64(clamping: drive.session.bytesRead), units: preferences.units))")
                Text("W \(Format.size(Int64(clamping: drive.session.bytesWritten), units: preferences.units))")
                Spacer()
            }
            .font(.caption2)
            .monospacedDigit()
            .accessibilityElement(children: .combine)
        } else {
            Text("No I/O statistics from this device")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// By kind, so nothing on the drive is read.
private struct DriveIcon: View {
    let drive: Drive
    @Environment(\.accent) private var accent

    var body: some View {
        Group {
            if drive.kind == .diskImage {
                Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: "dmg") ?? .diskImage))
                    .resizable()
            } else {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(accent)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }

    private var symbol: String {
        if drive.kind == .internal { return "internaldrive" }
        if drive.deviceProtocol == "Secure Digital" { return "sdcard" }
        return "externaldrive"
    }
}

private struct Rate: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(color)
            Text(value).monospacedDigit()
        }
        .font(.system(size: 13, weight: .semibold))
    }
}

/// Name, format, a used/total bar and free space.
struct VolumeRow<Accessory: View>: View {
    let volume: Volume
    let preferences: Preferences
    @ViewBuilder var accessory: Accessory
    @Environment(\.accent) private var accent

    private var isLow: Bool { volume.space.map(preferences.lowSpaceThreshold.isLow) ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(volume.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(volume.mountPath)
                Text(volume.format)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if isLow {
                    Text("! low")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 4)
                Text(volume.space.map { "\(Format.size($0.available, units: preferences.units)) free" } ?? "reading…")
                    .monospacedDigit()
                accessory
            }
            if let space = volume.space {
                UsageBar(fraction: space.usedFraction, color: isLow ? .orange : accent)
                    .frame(height: 5)
                Text(detail(space))
                    .font(.caption2)
                    .foregroundStyle(space.isStale ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// "1.4 TB used of 4.0 TB · 2.5 TB free without purging"
    private func detail(_ space: Space) -> String {
        let units = preferences.units
        var parts = ["\(Format.size(space.used, units: units)) used of \(Format.size(space.total, units: units))"]
        // Only when it reads differently from the free space above.
        let strict = Format.size(space.availableStrict, units: units)
        if space.available - space.availableStrict > 1_000_000_000, strict != Format.size(space.available, units: units) {
            parts.append("\(strict) free without purging")
        }
        if space.isStale { parts.append("not responding, last value shown") }
        return parts.joined(separator: " · ")
    }

    private var accessibilityText: String {
        guard let space = volume.space else { return "\(volume.name), reading" }
        let units = preferences.units
        var text = "\(volume.name), \(volume.format), \(Format.spoken(bytes: Double(space.available), units: units)) free of \(Format.spoken(bytes: Double(space.total), units: units)), \(Format.percent(space.usedFraction)) used"
        if isLow { text += ", low on space" }
        if space.isStale { text += ", not responding" }
        return text
    }
}

extension VolumeRow where Accessory == EmptyView {
    init(volume: Volume, preferences: Preferences) {
        self.init(volume: volume, preferences: preferences) { EmptyView() }
    }
}

private struct UsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(color)
                .frame(width: geometry.size.width * max(0, min(1, fraction)))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.tertiary)
                .clipShape(.rect(cornerRadius: 2.5))
        }
        .accessibilityHidden(true)
    }
}

/// Shares: space only, each with Unmount.
struct NetworkCard: View {
    let volumes: [Volume]
    let ejector: Ejector
    let preferences: Preferences

    var body: some View {
        Card(highlighted: volumes.contains { ejector.statuses[EjectTarget(networkVolume: $0).id]?.failure != nil }) {
            ForEach(Array(volumes.enumerated()), id: \.element.id) { index, volume in
                let target = EjectTarget(networkVolume: volume)
                let status = ejector.statuses[target.id]
                if index > 0 { Divider() }
                VolumeRow(volume: volume, preferences: preferences) {
                    Button {
                        Task { await ejector.eject(target) }
                    } label: {
                        Image(systemName: "eject")
                    }
                    .buttonStyle(.borderless)
                    .disabled(status.map { $0.phase != .idle } ?? false)
                    .help("Unmount")
                    .accessibilityLabel("Unmount \(volume.name)")
                }
                .contextMenu {
                    Button("Unmount") { Task { await ejector.eject(target) } }
                    Button("Who's Using This?") { Task { await ejector.inspect(target) } }
                }
                .id(target.id)
                if let status, status.phase == .ejecting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Unmounting…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if status != nil {
                    BlockersView(ejector: ejector, targetID: target.id)
                }
            }
        }
    }
}

/// A menu of actions popped up at the mouse, built only when it's shown.
@MainActor
enum ActionMenu {
    static func show(_ actions: [(title: String, perform: () -> Void)]) {
        let menu = NSMenu()
        for action in actions { menu.addItem(Item(action.title, action.perform)) }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private final class Item: NSMenuItem {
        private let perform: () -> Void

        init(_ title: String, _ perform: @escaping () -> Void) {
            self.perform = perform
            super.init(title: title, action: #selector(run), keyEquivalent: "")
            // The menu holds the item, so the weak target stays alive.
            target = self
        }

        @available(*, unavailable)
        required init(coder: NSCoder) { fatalError() }

        @objc private func run() { perform() }
    }
}
