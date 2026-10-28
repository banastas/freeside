import AppKit
import FreesideKit

/// Owns the status item. For now it shows the drive glyph and a menu listing
/// drives, their rates and their volumes, with Eject and "Who's Using
/// This?"; the popover and the other display styles come in M4 and M5.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let volumes: VolumeStore
    private let drives: DriveMonitor
    private let ejector: Ejector
    private let blockers: BlockersPanel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    init(volumes: VolumeStore, drives: DriveMonitor, ejector: Ejector) {
        self.volumes = volumes
        self.drives = drives
        self.ejector = ejector
        blockers = BlockersPanel(ejector: ejector)
        super.init()

        statusItem.autosaveName = "freeside"
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "freeside")
            image?.isTemplate = true
            button.image = image
            button.setAccessibilityLabel("freeside")
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        showMenu()
    }

    private func showMenu() {
        // Sample now so the rates in the menu are current.
        drives.setDetailed(true)

        let menu = NSMenu()
        menu.delegate = self
        let volumesByID = Dictionary(volumes.volumes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var listed: Set<Volume.ID> = []
        for kind in VolumeKind.allCases {
            let kindDrives = drives.drives.filter { $0.kind == kind }
            let loose = volumes.volumes.filter { volume in
                volume.kind == kind && !kindDrives.contains { $0.volumeIDs.contains(volume.id) }
            }
            guard !kindDrives.isEmpty || !loose.isEmpty else { continue }
            menu.addItem(.sectionHeader(title: Self.title(for: kind)))
            if kind == .external, kindDrives.count > 1 {
                menu.addItem(item("Eject All", #selector(ejectAll(_:)), kindDrives.map(EjectTarget.init(drive:))))
            }
            for drive in kindDrives {
                let line = NSMenuItem(title: Self.line(for: drive), action: nil, keyEquivalent: "")
                // The boot drive can't be ejected.
                if kind != .internal { line.submenu = actions(for: EjectTarget(drive: drive), eject: "Eject") }
                menu.addItem(line)
                for volume in drive.volumeIDs.compactMap({ volumesByID[$0] }) {
                    let item = NSMenuItem(title: Self.line(for: volume), action: nil, keyEquivalent: "")
                    item.indentationLevel = 1
                    menu.addItem(item)
                    listed.insert(volume.id)
                }
            }
            for volume in loose where !listed.contains(volume.id) {
                let line = NSMenuItem(title: Self.line(for: volume), action: nil, keyEquivalent: "")
                if volume.kind == .network { line.submenu = actions(for: EjectTarget(networkVolume: volume), eject: "Unmount") }
                menu.addItem(line)
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit freeside", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Shows the last values read; the next opening has fresh ones.
        volumes.refreshSpace()
    }

    private func actions(for target: EjectTarget, eject: String) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(eject, #selector(ejectTarget(_:)), target))
        menu.addItem(item("Who's Using This?", #selector(inspect(_:)), target))
        return menu
    }

    private func item(_ title: String, _ action: Selector, _ object: Any) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        return item
    }

    @objc private func ejectTarget(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? EjectTarget else { return }
        Task {
            if await !ejector.eject(target) { blockers.show(target.id) }
        }
    }

    @objc private func ejectAll(_ sender: NSMenuItem) {
        guard let targets = sender.representedObject as? [EjectTarget] else { return }
        Task {
            let result = await ejector.ejectAll(targets)
            // The popover lists what ejected (M5); for now, show the first failure.
            if let first = result.failed.first { blockers.show(first) }
        }
    }

    func showBlockers(_ id: EjectTarget.ID) {
        blockers.show(id)
    }

    @objc private func inspect(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? EjectTarget else { return }
        blockers.show(target.id)
        Task { await ejector.inspect(target) }
    }

    func menuDidClose(_ menu: NSMenu) {
        // Detach so the next click goes through handleClick again.
        statusItem.menu = nil
        drives.setDetailed(false)
    }

    private static func title(for kind: VolumeKind) -> String {
        switch kind {
        case .external: "External"
        case .diskImage: "Disk Images"
        case .network: "Network"
        case .internal: "Internal"
        }
    }

    /// "G-DRIVE SSD 55B7 · USB   R 412 MB/s  W 380 MB/s"
    private static func line(for drive: Drive) -> String {
        let name = [drive.name, drive.kind == .external ? drive.deviceProtocol : nil].compactMap(\.self).joined(separator: " · ")
        guard let read = drive.readRate, let write = drive.writeRate else { return "\(name)   no I/O statistics" }
        return "\(name)   R \(Format.rate(read))  W \(Format.rate(write))"
    }

    /// "Photography  2.6 TB free of 4.0 TB · APFS"
    private static func line(for volume: Volume) -> String {
        let space = volume.space.map { space in
            "\(Format.decimalBytes(UInt64(space.available))) free of \(Format.decimalBytes(UInt64(space.total)))" + (space.isStale ? " (stale)" : "")
        } ?? "reading…"
        return "\(volume.name)  \(space) · \(volume.format)"
    }
}
