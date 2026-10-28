import AppKit

/// Owns the status item. For now it shows the drive glyph and a menu with
/// Quit; the popover and the other display styles come in M4 and M5.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    override init() {
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
        menu.addItem(withTitle: "Quit freeside", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Detach so the next click goes through handleClick again.
        statusItem.menu = nil
    }
}
