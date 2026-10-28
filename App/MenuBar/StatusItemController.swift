import AppKit
import FreesideKit

/// Owns the status item. For now it shows the drive glyph and a menu listing
/// volumes and their free space; the popover and the other display styles
/// come in M4 and M5.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let volumes: VolumeStore
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    init(volumes: VolumeStore) {
        self.volumes = volumes
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
        let menu = NSMenu()
        menu.delegate = self
        for kind in VolumeKind.allCases {
            let group = volumes.volumes.filter { $0.kind == kind }
            guard !group.isEmpty else { continue }
            menu.addItem(.sectionHeader(title: Self.title(for: kind)))
            for volume in group {
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
    }

    private static func title(for kind: VolumeKind) -> String {
        switch kind {
        case .external: "External"
        case .diskImage: "Disk Images"
        case .network: "Network"
        case .internal: "Internal"
        }
    }

    /// "Photography  2.6 TB free of 4.0 TB · USB · APFS"
    private static func line(for volume: Volume) -> String {
        let space = volume.space.map { space in
            "\(Format.decimalBytes(UInt64(space.available))) free of \(Format.decimalBytes(UInt64(space.total)))" + (space.isStale ? " (stale)" : "")
        } ?? "reading…"
        let detail = [volume.kind == .external ? volume.deviceProtocol : nil, volume.format].compactMap(\.self).joined(separator: " · ")
        return "\(volume.name)  \(space) · \(detail)"
    }
}
