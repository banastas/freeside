import AppKit
import FreesideKit
import SwiftUI

/// A floating panel showing one target's blockers. Stands in for the
/// popover's Blockers panel until M5.
@MainActor
final class BlockersPanel {
    private let ejector: Ejector
    private var panel: NSPanel?

    init(ejector: Ejector) {
        self.ejector = ejector
    }

    func show(_ id: EjectTarget.ID) {
        panel?.close()
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "freeside"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.contentViewController = NSHostingController(rootView: BlockersView(ejector: ejector, targetID: id) { [weak self] in
            self?.panel?.close()
            self?.panel = nil
        })
        panel.center()
        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel
    }
}
