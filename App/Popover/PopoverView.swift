import AppKit
import FreesideKit
import Observation
import SwiftUI

/// What the popover keeps between openings.
@MainActor
@Observable
final class PopoverState {
    /// Shown under the header after Eject All, until the popover closes.
    var ejectAllResult: Ejector.EjectAllResult?
    var internalExpanded = false
    var showingSettings = false
    /// Scrolled to when the popover opens: the first failed eject.
    var focus: EjectTarget.ID?
}

extension EnvironmentValues {
    @Entry var accent: Color = Accent.phosphor.color
    @Entry var writeColor: Color = Accent.phosphor.writeColor
}

struct PopoverView: View {
    let volumes: VolumeStore
    let drives: DriveMonitor
    let ejector: Ejector
    let preferences: Preferences
    let notifier: Notifier
    let updater: Updater
    @Bindable var state: PopoverState
    let copyDiagnostics: () -> Void

    @State private var contentHeight: CGFloat = 0

    private struct FocusKey: Equatable {
        var focus: EjectTarget.ID?
        var laidOut: Bool
    }

    /// Leaves room for the header and footer below the menu bar.
    private var maxScrollHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) - 140
    }

    var body: some View {
        let model = PopoverModel(volumes: volumes.volumes, drives: drives.drives, shown: preferences.volumesShown)
        VStack(alignment: .leading, spacing: 10) {
            HeaderView(external: model.external, externalFree: model.externalFree, units: preferences.units)
            if let result = state.ejectAllResult {
                EjectAllSummary(result: result, ejector: ejector) { state.ejectAllResult = nil }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if state.showingSettings {
                            SettingsView(preferences: preferences, volumes: volumes, notifier: notifier, updater: updater, copyDiagnostics: copyDiagnostics)
                        } else {
                            sections(model)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { contentHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(contentHeight, maxScrollHeight))
                // Once the content has a height to scroll in.
                .onChange(of: FocusKey(focus: state.focus, laidOut: contentHeight > 0), initial: true) { _, key in
                    guard let id = key.focus, key.laidOut else { return }
                    proxy.scrollTo(id, anchor: .top)
                    state.focus = nil
                }
            }
            FooterView(state: state, updater: updater, external: model.external, ejector: ejector)
        }
        .padding(14)
        .frame(width: 340)
        // The default popover glass lets busy windows show through the numbers.
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.92))
        .fontDesign(.monospaced)
        .tint(preferences.accent.color)
        .environment(\.accent, preferences.accent.color)
        .environment(\.writeColor, preferences.accent.writeColor)
    }

    @ViewBuilder
    private func sections(_ model: PopoverModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.externalShown) { drive in
                DriveCard(drive: drive, volumes: model.volumes(on: drive), ejector: ejector, preferences: preferences, ejectable: true)
            }
            looseCards(model.loose(.external))

            if !model.images.isEmpty || !model.loose(.diskImage).isEmpty {
                SectionLabel(title: "disk images")
                ForEach(model.images) { drive in
                    DriveCard(drive: drive, volumes: model.volumes(on: drive), ejector: ejector, preferences: preferences, ejectable: true)
                }
                looseCards(model.loose(.diskImage))
            }

            if !model.network.isEmpty {
                SectionLabel(title: "network")
                NetworkCard(volumes: model.network, ejector: ejector, preferences: preferences)
            }

            if !model.internal.isEmpty || !model.loose(.internal).isEmpty {
                InternalSection(model: model, ejector: ejector, preferences: preferences, expanded: $state.internalExpanded)
            }
        }
    }

    /// Volumes with no device found under them: space only.
    @ViewBuilder
    private func looseCards(_ loose: [Volume]) -> some View {
        if !loose.isEmpty {
            Card {
                ForEach(loose) { volume in VolumeRow(volume: volume, preferences: preferences) }
            }
        }
    }
}

/// The popover's sections from the volume and drive lists, filtered by the
/// "Volumes shown" setting.
struct PopoverModel {
    let volumes: [Volume]
    let drives: [Drive]
    let shown: Set<VolumeKind>

    private var byID: [Volume.ID: Volume] {
        Dictionary(volumes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Every external drive, shown or not, for the header's count and Eject All.
    var external: [Drive] { drives.filter { $0.kind == .external } }
    var externalShown: [Drive] { shown.contains(.external) ? external : [] }
    var images: [Drive] { shown.contains(.diskImage) ? drives.filter { $0.kind == .diskImage } : [] }
    var `internal`: [Drive] { shown.contains(.internal) ? drives.filter { $0.kind == .internal } : [] }
    var network: [Volume] { shown.contains(.network) ? volumes.filter { $0.kind == .network } : [] }

    /// Free space across every external drive's volumes, for the header;
    /// nil until one has been read.
    var externalFree: Int64? {
        let spaces = external.flatMap(volumes(on:)).compactMap(\.space)
        return spaces.isEmpty ? nil : spaces.reduce(0) { $0 + $1.available }
    }

    func volumes(on drive: Drive) -> [Volume] {
        let byID = byID
        return drive.volumeIDs.compactMap { byID[$0] }
    }

    func loose(_ kind: VolumeKind) -> [Volume] {
        guard shown.contains(kind) else { return [] }
        let onDrives = Set(drives.flatMap(\.volumeIDs))
        return volumes.filter { $0.kind == kind && !onDrives.contains($0.id) }
    }
}

/// As in flatline: the name on the left, two quiet lines on the right,
/// here the external drives and their free space.
private struct HeaderView: View {
    let external: [Drive]
    let externalFree: Int64?
    let units: ByteUnits
    @Environment(\.accent) private var accent

    private var count: String {
        switch external.count {
        case 0: "No external drives"
        case 1: "1 external drive"
        default: "\(external.count) external drives"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "externaldrive")
                .font(.headline)
            Text("freeside")
                .font(.headline)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(count)
                if let externalFree, !external.isEmpty {
                    Text("\(Format.size(externalFree, units: units)) free")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
        .foregroundStyle(accent)
    }
}

/// "Ejected RAID and G-DRIVE. Photos couldn't be ejected."
private struct EjectAllSummary: View {
    let result: Ejector.EjectAllResult
    let ejector: Ejector
    let close: () -> Void

    private var text: String {
        var sentences: [String] = []
        if !result.ejected.isEmpty {
            sentences.append("Ejected \(result.ejected.formatted(.list(type: .and))).")
        }
        let failed = result.failed.compactMap { ejector.statuses[$0]?.target.name }
        if !failed.isEmpty {
            sentences.append("\(failed.formatted(.list(type: .and))) couldn't be ejected.")
        } else if !result.failed.isEmpty {
            sentences.append("\(result.failed.count) couldn't be ejected.")
        }
        return sentences.joined(separator: " ")
    }

    var body: some View {
        HStack(alignment: .top) {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .font(.caption)
        .padding(8)
        .background(.fill.quinary, in: .rect(cornerRadius: 8))
    }
}

/// Settings, the version (or an available update), Eject All and Quit.
private struct FooterView: View {
    @Bindable var state: PopoverState
    let updater: Updater
    let external: [Drive]
    let ejector: Ejector

    private var ejecting: Bool {
        ejector.statuses.values.contains { $0.phase == .ejecting }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        HStack {
            Button {
                state.showingSettings.toggle()
            } label: {
                Label(state.showingSettings ? "done" : "settings", systemImage: state.showingSettings ? "chevron.left" : "gearshape")
            }
            .keyboardShortcut(",")
            if let available = updater.availableVersion {
                // A check found a newer version; this opens Sparkle's window for it.
                Button {
                    updater.checkForUpdates()
                } label: {
                    Label("update to \(available)", systemImage: "arrow.down.circle")
                }
                .help("freeside \(available) is available")
            } else {
                Text("v\(version)")
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if !external.isEmpty, !state.showingSettings {
                Button {
                    let targets = external.map(EjectTarget.init(drive:))
                    Task {
                        let result = await ejector.ejectAll(targets)
                        state.ejectAllResult = result
                        state.focus = result.failed.first
                    }
                } label: {
                    // Just the symbol when an available update needs the room.
                    ViewThatFits {
                        Label("eject all", systemImage: "eject")
                        Image(systemName: "eject")
                    }
                }
                .disabled(ejecting)
                .accessibilityLabel("Eject all external drives")
                .padding(.trailing, 10)
            }
            Button("quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }
}

struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(1.5)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }
}

/// The boot drive and any other internal disk, collapsed by default.
private struct InternalSection: View {
    let model: PopoverModel
    let ejector: Ejector
    let preferences: Preferences
    @Binding var expanded: Bool

    /// "Macintosh HD · 245 GB free"
    private var summary: String {
        let boot = model.volumes.first { $0.isBoot && model.shown.contains($0.kind) }
        guard let boot, let space = boot.space else { return "" }
        return "\(boot.name) · \(Format.size(space.available, units: preferences.units)) free"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    SectionLabel(title: "internal")
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Internal disk, \(summary)")
            .accessibilityValue(expanded ? "expanded" : "collapsed")

            if expanded {
                ForEach(model.internal) { drive in
                    DriveCard(drive: drive, volumes: model.volumes(on: drive), ejector: ejector, preferences: preferences, ejectable: false)
                }
                let loose = model.loose(.internal)
                if !loose.isEmpty {
                    Card {
                        ForEach(loose) { volume in VolumeRow(volume: volume, preferences: preferences) }
                    }
                }
            }
        }
    }
}
