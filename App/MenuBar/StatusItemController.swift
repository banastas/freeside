import AppKit
import FreesideKit

/// Owns the status item. For now it shows the drive glyph and a menu listing
/// drives, their rates and their volumes; the popover and the other display
/// styles come in M4 and M5.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let volumes: VolumeStore
    private let drives: DriveMonitor
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    init(volumes: VolumeStore, drives: DriveMonitor) {
        self.volumes = volumes
        self.drives = drives
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
            for drive in kindDrives {
                menu.addItem(withTitle: Self.line(for: drive), action: nil, keyEquivalent: "")
                for volume in drive.volumeIDs.compactMap({ volumesByID[$0] }) {
                    let item = NSMenuItem(title: Self.line(for: volume), action: nil, keyEquivalent: "")
                    item.indentationLevel = 1
                    menu.addItem(item)
                    listed.insert(volume.id)
                }
            }
            for volume in loose where !listed.contains(volume.id) {
                menu.addItem(withTitle: Self.line(for: volume), action: nil, keyEquivalent: "")
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit freeside", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Shows the last values read; the next opening has fresh ones.
        volumes.refreshSpace()
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
