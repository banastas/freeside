import AppKit
import FreesideKit
import ImageIO
import Observation

/// Owns the status item: draws it in the chosen style, switches to activity
/// during transfers, and opens menus. A click shows drives, their rates and
/// volumes, with Eject and "Who's Using This?" (the popover replaces it in
/// M5); a right-click or Control-click shows the app menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let volumes: VolumeStore
    private let drives: DriveMonitor
    private let ejector: Ejector
    private let preferences: Preferences
    private let blockers: BlockersPanel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    private var transfer = TransferDetector()
    private var drivesMenuOpen = false

    private struct RenderKey: Equatable {
        var layout: MenuBarRenderer.Layout
        var appearance: NSAppearance.Name
        var scale: CGFloat
    }
    private var lastRender: RenderKey?
    private var appearanceObservation: NSKeyValueObservation?

    /// Holds the rendered bitmap. Setting `button.image` instead makes NSButton
    /// re-render the image on the CPU every tick (flatline measured ~2 ms); a
    /// layer's contents go straight to the window server.
    private let contentLayer = CALayer()
    private static let horizontalPadding: CGFloat = 4

    init(volumes: VolumeStore, drives: DriveMonitor, ejector: Ejector, preferences: Preferences) {
        self.volumes = volumes
        self.drives = drives
        self.ejector = ejector
        self.preferences = preferences
        blockers = BlockersPanel(ejector: ejector)
        super.init()

        statusItem.autosaveName = "freeside"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.wantsLayer = true
            contentLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            button.layer?.addSublayer(contentLayer)
            // The icon style has no timer, so appearance and display changes
            // have to trigger their own redraws.
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.redraw() }
            }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(backingChanged(_:)), name: NSWindow.didChangeBackingPropertiesNotification, object: nil
        )

        drives.onSample = { [weak self] in self?.sampled() }
        observeModel()
        updateSampling()
        redraw()
    }

    // MARK: - Drawing

    private func sampled() {
        if transfer.update(rate: drives.externalReadRate + drives.externalWriteRate, at: .now) {
            updateSampling()
        }
        redraw()
    }

    private var visibleVolumes: [Volume] {
        volumes.volumes.filter { preferences.volumesShown.contains($0.kind) }
    }

    private var effectiveStyle: MenuBarStyle {
        preferences.menuBarStyle.effective(
            pinnedMounted: preferences.pinnedVolume(in: volumes.volumes) != nil,
            transferring: transfer.isActive,
            activityDuringTransfers: preferences.activityDuringTransfers
        )
    }

    private func redraw() {
        guard let button = statusItem.button else { return }
        let hasExternal = drives.drives.contains { $0.kind == .external }
        statusItem.isVisible = !(preferences.hideWhenNoExternal && !hasExternal)

        let style = effectiveStyle
        let pinned = preferences.pinnedVolume(in: volumes.volumes)
        let threshold = preferences.lowSpaceThreshold
        let low = visibleVolumes.filter { $0.space.map(threshold.isLow) == true }
        let inputs = MenuBarRenderer.Inputs(
            style: style,
            reserved: preferences.menuBarStyle.reserved(activityDuringTransfers: preferences.activityDuringTransfers),
            pinnedName: pinned?.name ?? "",
            pinnedAvailable: Double(pinned?.space?.available ?? 0),
            pinnedLow: pinned?.space.map(threshold.isLow) == true,
            anyLow: !low.isEmpty,
            readRate: drives.externalReadRate,
            writeRate: drives.externalWriteRate,
            trace: preferences.activityTrace ? drives.externalTrace(Int(MenuBarRenderer.traceWidth)) : nil,
            units: preferences.units
        )
        volumes.setSpaceVisible(style.showsSpace)

        let label = accessibilityLabel(pinned: pinned, low: low)
        if button.accessibilityLabel() != label { button.setAccessibilityLabel(label) }
        let tip = pinned.map(Self.tooltip)
        if button.toolTip != tip { button.toolTip = tip }

        let layout = MenuBarRenderer.layout(inputs)
        let appearance = button.effectiveAppearance
        let scale = button.window?.backingScaleFactor ?? 2
        let key = RenderKey(layout: layout, appearance: appearance.name, scale: scale)
        guard key != lastRender else { return }
        lastRender = key

        guard let image = MenuBarRenderer.image(for: layout, appearance: appearance, scale: scale) else { return }
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let length = size.width + 2 * Self.horizontalPadding
        if statusItem.length != length { statusItem.length = length }
        contentLayer.contentsScale = scale
        contentLayer.frame = CGRect(x: Self.horizontalPadding, y: ((button.bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
        contentLayer.contents = image
        if let path = Self.snapshotPath { Self.writeSnapshot(image, to: path) }
    }

    /// Every second while rates are on screen or a transfer may be starting;
    /// otherwise DriveMonitor's 5 s check.
    private func updateSampling() {
        drives.setDetailed(drivesMenuOpen || effectiveStyle.showsActivity || transfer.isPending)
    }

    /// Redraws when volumes, space or settings change, without waiting for a tick.
    private func observeModel() {
        withObservationTracking {
            _ = volumes.volumes
            _ = drives.drives.map(\.kind)
            _ = preferences.menuBarStyle
            _ = preferences.pinnedVolumeID
            _ = preferences.activityDuringTransfers
            _ = preferences.activityTrace
            _ = preferences.units
            _ = preferences.lowSpaceThreshold
            _ = preferences.volumesShown
            _ = preferences.hideWhenNoExternal
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.updateSampling()
                self.redraw()
                self.observeModel()
            }
        }
    }

    @objc private func backingChanged(_ notification: Notification) {
        guard (notification.object as? NSWindow) == statusItem.button?.window else { return }
        redraw()
    }

    /// "2 external drives. RAID, 1.2 terabytes free, writing 380 megabytes per second."
    private func accessibilityLabel(pinned: Volume?, low: [Volume]) -> String {
        let external = drives.drives.filter { $0.kind == .external }.count
        var sentences = [external == 0 ? "No external drives" : external == 1 ? "1 external drive" : "\(external) external drives"]
        var details: [String] = []
        if let pinned, let space = pinned.space {
            details.append("\(pinned.name), \(Format.spoken(bytes: Double(space.available), units: preferences.units)) free")
        }
        if drives.externalReadRate >= 1000 {
            details.append("reading \(Format.spoken(bytes: drives.externalReadRate, units: preferences.units, perSecond: true))")
        }
        if drives.externalWriteRate >= 1000 {
            details.append("writing \(Format.spoken(bytes: drives.externalWriteRate, units: preferences.units, perSecond: true))")
        }
        if !details.isEmpty { sentences.append(details.joined(separator: ", ")) }
        if !low.isEmpty { sentences.append("Low on space: \(low.map(\.name).formatted(.list(type: .and)))") }
        return sentences.joined(separator: ". ") + "."
    }

    /// The pinned volume's full name, which the caption may truncate.
    private static func tooltip(_ volume: Volume) -> String {
        guard let space = volume.space else { return volume.name }
        return "\(volume.name): \(Format.decimalBytes(UInt64(space.available))) free of \(Format.decimalBytes(UInt64(space.total)))"
    }

    // MARK: - Clicks

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showAppMenu()
        } else {
            showDrivesMenu()
        }
    }

    private func showDrivesMenu() {
        drivesMenuOpen = true
        updateSampling()

        let menu = NSMenu()
        menu.delegate = self
        let volumesByID = Dictionary(volumes.volumes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var listed: Set<Volume.ID> = []
        for kind in VolumeKind.allCases where preferences.volumesShown.contains(kind) {
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
                let driveLine = NSMenuItem(title: Self.line(for: drive), action: nil, keyEquivalent: "")
                // The boot drive can't be ejected.
                if kind != .internal { driveLine.submenu = actions(for: EjectTarget(drive: drive), eject: "Eject") }
                menu.addItem(driveLine)
                for volume in drive.volumeIDs.compactMap({ volumesByID[$0] }) {
                    let volumeLine = NSMenuItem(title: line(for: volume), action: nil, keyEquivalent: "")
                    volumeLine.indentationLevel = 1
                    menu.addItem(volumeLine)
                    listed.insert(volume.id)
                }
            }
            for volume in loose where !listed.contains(volume.id) {
                let volumeLine = NSMenuItem(title: line(for: volume), action: nil, keyEquivalent: "")
                if volume.kind == .network { volumeLine.submenu = actions(for: EjectTarget(networkVolume: volume), eject: "Unmount") }
                menu.addItem(volumeLine)
            }
        }
        if menu.items.isEmpty { menu.addItem(withTitle: "No volumes", action: nil, keyEquivalent: "") }
        open(menu)
        // Shows the last values read; the next opening has fresh ones.
        volumes.refreshSpace()
    }

    private func showAppMenu() {
        let menu = NSMenu()
        menu.delegate = self
        let external = drives.drives.filter { $0.kind == .external }.map(EjectTarget.init(drive:))
        let ejectAll = item("Eject All", #selector(ejectAll(_:)), external)
        if external.isEmpty { ejectAll.action = nil }
        menu.addItem(ejectAll)
        menu.addItem(item("Open freeside", #selector(openDrives), ""))
        menu.addItem(.separator())
        menu.addItem(menuBarSettings())
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit freeside", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        open(menu)
    }

    /// The menu bar settings, until the settings panel lands in M6.
    private func menuBarSettings() -> NSMenuItem {
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: "Style"))
        for style in MenuBarStyle.allCases {
            menu.addItem(choice(style.label, selected: preferences.menuBarStyle == style) { $0.menuBarStyle = style })
        }

        let pinned = NSMenu()
        let automatic = Volume.defaultPinned(in: volumes.volumes).map { "Automatic (\($0.name))" } ?? "Automatic"
        pinned.addItem(choice(automatic, selected: preferences.pinnedVolumeID == nil) { $0.pinnedVolumeID = nil })
        pinned.addItem(.separator())
        for volume in volumes.volumes {
            pinned.addItem(choice(volume.name, selected: preferences.pinnedVolumeID == volume.id) { $0.pinnedVolumeID = volume.id })
        }
        if let id = preferences.pinnedVolumeID, !volumes.volumes.contains(where: { $0.id == id }) {
            let missing = NSMenuItem(title: "Not mounted", action: nil, keyEquivalent: "")
            missing.state = .on
            pinned.addItem(missing)
        }
        let pinnedItem = NSMenuItem(title: "Volume for Space", action: nil, keyEquivalent: "")
        pinnedItem.submenu = pinned
        menu.addItem(.separator())
        menu.addItem(pinnedItem)

        menu.addItem(choice("Show Activity During Transfers", selected: preferences.activityDuringTransfers) { $0.activityDuringTransfers.toggle() })
        menu.addItem(choice("Activity Trace", selected: preferences.activityTrace) { $0.activityTrace.toggle() })
        menu.addItem(choice("Hide When No External Drives", selected: preferences.hideWhenNoExternal) { $0.hideWhenNoExternal.toggle() })

        menu.addItem(.sectionHeader(title: "Units"))
        for units in ByteUnits.allCases {
            menu.addItem(choice(units.label, selected: preferences.units == units) { $0.units = units })
        }
        menu.addItem(.sectionHeader(title: "Low Space"))
        for threshold in LowSpaceThreshold.presets {
            menu.addItem(choice("Below \(threshold.label)", selected: preferences.lowSpaceThreshold == threshold) { $0.lowSpaceThreshold = threshold })
        }

        let item = NSMenuItem(title: "Menu Bar", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func open(_ menu: NSMenu) {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Detach so the next click goes through handleClick again.
        statusItem.menu = nil
        drivesMenuOpen = false
        updateSampling()
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

    private final class Choice {
        let apply: (Preferences) -> Void
        init(_ apply: @escaping (Preferences) -> Void) { self.apply = apply }
    }

    private func choice(_ title: String, selected: Bool, apply: @escaping (Preferences) -> Void) -> NSMenuItem {
        let item = item(title, #selector(choose(_:)), Choice(apply))
        item.state = selected ? .on : .off
        return item
    }

    @objc private func choose(_ sender: NSMenuItem) {
        (sender.representedObject as? Choice)?.apply(preferences)
    }

    @objc private func openDrives() {
        // After the app menu has closed.
        DispatchQueue.main.async { [weak self] in self?.showDrivesMenu() }
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

    // MARK: - Menu lines

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

    /// "Photography  2.6 TB free of 4.0 TB · APFS", with "low" below the threshold.
    private func line(for volume: Volume) -> String {
        let space = volume.space.map { space in
            "\(Format.decimalBytes(UInt64(space.available))) free of \(Format.decimalBytes(UInt64(space.total)))"
                + (space.isStale ? " (stale)" : "")
                + (preferences.lowSpaceThreshold.isLow(space) ? " · low" : "")
        } ?? "reading…"
        return "\(volume.name)  \(space) · \(volume.format)"
    }

    // MARK: - Development

    /// `FREESIDE_SNAPSHOT=<file.png>` writes every rendered menu bar image to
    /// that file, for checking rendering without a screen capture.
    private static let snapshotPath = ProcessInfo.processInfo.environment["FREESIDE_SNAPSHOT"]

    private static func writeSnapshot(_ image: CGImage, to path: String) {
        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
