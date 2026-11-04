import AppKit
import FreesideKit
import ImageIO
import Observation
import SwiftUI

/// Owns the status item: draws it in the chosen style, switches to activity
/// during transfers, opens the popover on click and the app menu on a
/// right-click or Control-click.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate, NSMenuDelegate {
    private let volumes: VolumeStore
    private let drives: DriveMonitor
    private let ejector: Ejector
    private let preferences: Preferences
    private let notifier: Notifier
    private let updater: Updater
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    /// Created per opening and released on close, so the popover's views
    /// exist only while it's open.
    private var popover: NSPopover?
    private let popoverState: PopoverState = {
        let state = PopoverState()
        state.internalExpanded = Dump.expandsInternal
        return state
    }()

    private var transfer = TransferDetector()
    private var popoverOpen: Bool { popover?.isShown == true }

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

    init(volumes: VolumeStore, drives: DriveMonitor, ejector: Ejector, preferences: Preferences, notifier: Notifier, updater: Updater) {
        self.volumes = volumes
        self.drives = drives
        self.ejector = ejector
        self.preferences = preferences
        self.notifier = notifier
        self.updater = updater
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
        Profiler.endTick()
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
        statusItem.isVisible = !(preferences.hideWhenNoExternal && !drives.hasExternal)

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
            trace: preferences.menuBarStyle.showsTrace(traceOn: preferences.activityTrace) ? drives.externalTrace(Int(MenuBarRenderer.traceWidth)) : nil,
            units: preferences.units
        )
        volumes.setSpaceVisible(style.showsSpace || popoverOpen)

        Profiler.measure("a11y") {
            let label = accessibilityLabel(pinned: pinned, low: low)
            if button.accessibilityLabel() != label { button.setAccessibilityLabel(label) }
            let tip = pinned.map(Self.tooltip)
            if button.toolTip != tip { button.toolTip = tip }
        }

        let layout = Profiler.measure("layout") { MenuBarRenderer.layout(inputs) }
        let appearance = button.effectiveAppearance
        let scale = button.window?.backingScaleFactor ?? 2
        let key = RenderKey(layout: layout, appearance: appearance.name, scale: scale)
        guard key != lastRender else { return }
        lastRender = key

        guard let image = Profiler.measure("render", { MenuBarRenderer.image(for: layout, appearance: appearance, scale: scale) }) else { return }
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let length = size.width + 2 * Self.horizontalPadding
        if statusItem.length != length { statusItem.length = length }
        contentLayer.contentsScale = scale
        contentLayer.frame = CGRect(x: Self.horizontalPadding, y: ((button.bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
        contentLayer.contents = image
        if let path = Self.snapshotPath {
            Self.writeSnapshot(image, to: path)
            // And as it would look on the other menu bar, for the README.
            let other = NSAppearance(named: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .aqua : .darkAqua)!
            if let image = MenuBarRenderer.image(for: layout, appearance: other, scale: scale) {
                Self.writeSnapshot(image, to: (path as NSString).deletingPathExtension + (other.name == .aqua ? "-light.png" : "-dark.png"))
            }
        }
    }

    /// Every second while rates are on screen or a transfer may be starting;
    /// otherwise DriveMonitor's 5 s check.
    private func updateSampling() {
        drives.setDetailed(popoverOpen || effectiveStyle.showsActivity || transfer.isPending)
    }

    /// Redraws when volumes, space or settings change, without waiting for a tick.
    private func observeModel() {
        withObservationTracking {
            _ = volumes.volumes
            _ = drives.hasExternal
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
        } else if popoverOpen {
            popover?.performClose(nil)
        } else {
            showPopover()
        }
    }

    /// Opens the popover, scrolled to `focus` if given, or on its settings.
    func showPopover(focus: EjectTarget.ID? = nil, settings: Bool = false) {
        popoverState.focus = focus
        popoverState.showingSettings = settings
        guard !popoverOpen, let button = statusItem.button else { return }
        let opening = ContinuousClock.now
        dismissStaleStatuses()

        let view = PopoverView(
            volumes: volumes, drives: drives, ejector: ejector, preferences: preferences, notifier: notifier, updater: updater,
            state: popoverState
        ) { [weak self] in
            self?.copyDiagnostics()
        }
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = .preferredContentSize

        let popover = NSPopover()
        // Launched from a shell, freeside can't activate itself, and a
        // transient popover then closes at the first change of key window.
        popover.behavior = Dump.isHooked ? .applicationDefined : .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = controller
        self.popover = popover

        NSApp.activate()
        if Profiler.enabled {
            // PRD §8: popover open → first frame under 100 ms. The transaction
            // that shows it commits at the end of this run loop pass.
            CATransaction.setCompletionBlock {
                let elapsed = ContinuousClock.now - opening
                FileHandle.standardError.write(Data("popover first frame \(elapsed.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))\n".utf8))
            }
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Without key status the popover draws its controls inactive.
        controller.view.window?.makeKey()
        updateSampling()
        volumes.setSpaceVisible(true)
        // Shows the last values read until these come back.
        volumes.refreshSpace()
    }

    func closePopover() {
        popover?.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        popoverState.ejectAllResult = nil
        // Release the popover, its window and the SwiftUI tree once AppKit has
        // finished closing it.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.popover?.isShown != true else { return }
            self.popover = nil
            self.updateSampling()
            self.redraw()
        }
    }

    /// A target whose drive has gone (ejected from Finder, unplugged) has
    /// nothing left to show.
    private func dismissStaleStatuses() {
        let live = Set(drives.drives.map { EjectTarget(drive: $0).id }
            + volumes.volumes.filter { $0.kind == .network }.map { EjectTarget(networkVolume: $0).id })
        for (id, status) in ejector.statuses where !live.contains(id) && status.phase == .idle {
            ejector.dismiss(id)
        }
    }

    private func showAppMenu() {
        let menu = NSMenu()
        menu.delegate = self
        let external = drives.drives.filter { $0.kind == .external }.map(EjectTarget.init(drive:))
        let ejectAll = item("Eject All", #selector(ejectAll(_:)), external)
        if external.isEmpty { ejectAll.action = nil }
        menu.addItem(ejectAll)
        menu.addItem(item("Open freeside", #selector(openPopover), ""))
        let settings = item("Settings…", #selector(openSettings), "")
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(item("Copy Diagnostics", #selector(copyDiagnosticsFromMenu), ""))
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates), ""))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit freeside", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        open(menu)
    }

    private func open(_ menu: NSMenu) {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Detach so the next click goes through handleClick again.
        statusItem.menu = nil
    }

    private func item(_ title: String, _ action: Selector, _ object: Any) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        return item
    }

    @objc private func openPopover() {
        // After the app menu has closed.
        DispatchQueue.main.async { [weak self] in self?.showPopover() }
    }

    @objc private func openSettings() {
        DispatchQueue.main.async { [weak self] in self?.showPopover(settings: true) }
    }

    @objc private func checkForUpdates() {
        updater.checkForUpdates()
    }

    @objc private func copyDiagnosticsFromMenu() {
        copyDiagnostics()
    }

    /// Plain text on the clipboard; nothing is sent (PRD §6.8).
    private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticsReport(), forType: .string)
    }

    func diagnosticsReport() -> String {
        Diagnostics.report(
            environment: .current(settings: preferences.summary),
            volumes: volumes.volumes,
            drives: drives.drives,
            log: ejector.log,
            lastScan: ejector.lastScan
        )
    }

    /// From the app menu: the popover then lists what ejected and shows the
    /// first failure's blockers.
    @objc private func ejectAll(_ sender: NSMenuItem) {
        guard let targets = sender.representedObject as? [EjectTarget] else { return }
        Task {
            let result = await ejector.ejectAll(targets)
            guard !result.failed.isEmpty else { return }
            showPopover(focus: result.failed.first)
            popoverState.ejectAllResult = result
        }
    }

    // MARK: - Development

    /// `FREESIDE_SNAPSHOT=<file.png>` writes every rendered menu bar image to
    /// that file, and the same image for the other menu bar appearance next
    /// to it (`<file>-light.png` or `<file>-dark.png`), for checking
    /// rendering without a screen capture.
    private static let snapshotPath = ProcessInfo.processInfo.environment["FREESIDE_SNAPSHOT"]

    private static func writeSnapshot(_ image: CGImage, to path: String) {
        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
