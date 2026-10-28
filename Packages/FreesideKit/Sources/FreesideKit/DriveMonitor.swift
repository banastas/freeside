import AppKit
import DiskArbitration
import Observation

/// A physical drive, or a set of them for an AppleRAID volume, with the
/// volumes on it and its I/O rates.
public struct Drive: Identifiable, Sendable {
    /// The member drivers' registry IDs, joined.
    public let id: String
    public var name: String
    public var deviceProtocol: String?
    public var kind: VolumeKind
    public var members: [BlockDevice]
    public var volumeIDs: [Volume.ID]
    /// Bytes per second. Nil when a member publishes no statistics.
    public var readRate: Double?
    public var writeRate: Double?
    public var readTrace = RingBuffer<Double>(capacity: DriveMonitor.traceLength, fill: 0)
    public var writeTrace = RingBuffer<Double>(capacity: DriveMonitor.traceLength, fill: 0)
    /// Bytes moved since freeside first saw the drive.
    public var session = IOCounters(bytesRead: 0, bytesWritten: 0)
}

/// Samples I/O counters for every drive with a visible volume.
///
/// With no external drives there is no timer at all. With one attached, it
/// samples every second while rates are on screen (`setDetailed(true)`) and
/// every 5 s otherwise, which is enough to notice a transfer starting. While
/// the display sleeps it stops, unless a transfer is running.
@MainActor
@Observable
public final class DriveMonitor {
    public nonisolated static let traceLength = 60
    nonisolated static let minimumSampleInterval: Duration = .milliseconds(250)
    /// Combined rate above which a transfer is running.
    public nonisolated static let transferThreshold: Double = 1_000_000

    /// In popover order: external drives, disk images, then internal.
    public private(set) var drives: [Drive] = []
    /// Combined across physical external drives only. A disk image's I/O
    /// also lands on the drive holding its file, so images are left out.
    public private(set) var externalReadRate: Double = 0
    public private(set) var externalWriteRate: Double = 0

    public var isTransferring: Bool { externalReadRate + externalWriteRate > Self.transferThreshold }

    /// The last `count` seconds of combined external read and write rates,
    /// oldest first, for the menu bar trace.
    public func externalTrace(_ count: Int) -> (read: [Double], write: [Double]) {
        var read = [Double](repeating: 0, count: count)
        var write = [Double](repeating: 0, count: count)
        for drive in drives where drive.kind == .external {
            for (index, value) in drive.readTrace.suffix(count).enumerated() { read[index] += value }
            for (index, value) in drive.writeTrace.suffix(count).enumerated() { write[index] += value }
        }
        return (read, write)
    }

    @ObservationIgnored private let volumes: VolumeStore
    @ObservationIgnored private var drivers: [UInt64: BlockDriver] = [:]
    @ObservationIgnored private var baselines: [UInt64: IOCounters] = [:]
    @ObservationIgnored private var lastCounters: [UInt64: IOCounters] = [:]
    @ObservationIgnored private var lastSample: ContinuousClock.Instant?
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var timerInterval: Int?
    @ObservationIgnored private var detailed = false
    @ObservationIgnored private var displayAsleep = false
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var started = false
    /// Called after every sample, for redrawing the menu bar.
    @ObservationIgnored public var onSample: (() -> Void)?

    public init(volumes: VolumeStore) {
        self.volumes = volumes
    }

    public func start() {
        guard !started else { return }
        started = true
        observeSleep()
        observeVolumes()
    }

    public func stop() {
        started = false
        setTimer(nil)
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
    }

    /// True while rates are on screen: the popover is open, or the menu bar
    /// shows activity, or a transfer may be starting. Samples at once when it
    /// turns on; does nothing if unchanged.
    public func setDetailed(_ detailed: Bool) {
        guard detailed != self.detailed else { return }
        self.detailed = detailed
        updateTimer()
        if detailed { sample() }
    }

    // MARK: - Drives

    private func observeVolumes() {
        withObservationTracking {
            remap(volumes.volumes)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.started else { return }
                self.observeVolumes()
            }
        }
    }

    /// Runs when the volume list changes, never per tick.
    private func remap(_ volumes: [Volume]) {
        // Group volumes by the exact set of physical devices under them.
        var groups: [[BlockDevice]: [Volume]] = [:]
        var order: [[BlockDevice]] = []
        for volume in volumes {
            guard let bsdName = volume.bsdName else { continue }
            let members = DeviceMap.devices(forBSDName: bsdName)
            guard !members.isEmpty else { continue }
            if groups[members] == nil { order.append(members) }
            groups[members, default: []].append(volume)
        }

        let previous = Dictionary(drives.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var next: [Drive] = []
        var liveDrivers: [UInt64: BlockDriver] = [:]
        for members in order {
            let group = groups[members]!
            for device in members {
                liveDrivers[device.driverID] = drivers[device.driverID] ?? BlockDriver(device)
            }
            let id = members.map { String($0.driverID) }.joined(separator: "+")
            if var drive = previous[id] {
                drive.volumeIDs = group.map(\.id)
                drive.kind = group.map(\.kind).min()!
                next.append(drive)
            } else {
                next.append(Drive(
                    id: id,
                    name: Self.name(for: members, volumes: group),
                    deviceProtocol: group.first?.deviceProtocol,
                    kind: group.map(\.kind).min()!,
                    members: members,
                    volumeIDs: group.map(\.id)
                ))
            }
        }
        next.sort { $0.kind < $1.kind }

        drivers = liveDrivers
        baselines = baselines.filter { liveDrivers[$0.key] != nil }
        lastCounters = lastCounters.filter { liveDrivers[$0.key] != nil }
        for driver in liveDrivers.values where baselines[driver.device.driverID] == nil {
            if let counters = driver.counters() {
                baselines[driver.device.driverID] = counters
                lastCounters[driver.device.driverID] = counters
            }
        }
        drives = next
        updateTimer()
    }

    /// The device model, "2 × model" for a set of identical drives.
    private static func name(for members: [BlockDevice], volumes: [Volume]) -> String {
        // Every disk image's model is "Disk Image"; its file name says which.
        if volumes.allSatisfy({ $0.kind == .diskImage }), members.count == 1,
           let image = BlockerScanner.attachedImages().first(where: { $0.bsdName == members[0].bsdName }) {
            return image.fileName
        }
        let models = members.map { model(of: $0.bsdName) ?? volumes.first?.deviceModel ?? $0.bsdName }
        if Set(models).count == 1, models.count > 1 { return "\(models.count) × \(models[0])" }
        return models.joined(separator: " + ")
    }

    private static func model(of bsdName: String) -> String? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName),
              let description = DADiskCopyDescription(disk) as? [String: Any]
        else { return nil }
        return (description[kDADiskDescriptionDeviceModelKey as String] as? String)?.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Sampling

    func sample() {
        let now = ContinuousClock.now
        // Right after another sample (turning detailed mode on samples at
        // once), the counters have barely moved and the rates would read 0.
        if let lastSample, now - lastSample < Self.minimumSampleInterval { return }
        let elapsed = lastSample.map { (now - $0).timeInterval } ?? 0
        lastSample = now

        var current: [UInt64: IOCounters] = [:]
        for (id, driver) in drivers {
            if let counters = driver.counters() { current[id] = counters }
        }

        var externalRead = 0.0, externalWrite = 0.0
        for index in drives.indices {
            var drive = drives[index]
            let ids = drive.members.map(\.driverID)
            guard ids.allSatisfy({ current[$0] != nil }) else {
                drive.readRate = nil
                drive.writeRate = nil
                drives[index] = drive
                continue
            }
            let delta = ids.reduce(IOCounters(bytesRead: 0, bytesWritten: 0)) { sum, id in
                sum + current[id]!.since(lastCounters[id] ?? current[id]!)
            }
            drive.session = ids.reduce(IOCounters(bytesRead: 0, bytesWritten: 0)) { sum, id in
                sum + current[id]!.since(baselines[id] ?? current[id]!)
            }
            let (read, write) = Self.rates(delta, over: elapsed)
            drive.readRate = read
            drive.writeRate = write
            // A 5 s sample stands for five seconds of the trace.
            for _ in 0..<max(1, Int(elapsed.rounded())) where elapsed > 0 {
                drive.readTrace.append(read)
                drive.writeTrace.append(write)
            }
            if drive.kind == .external {
                externalRead += read
                externalWrite += write
            }
            drives[index] = drive

            // Free space only changes when something writes.
            if write > 0 {
                for volumeID in drive.volumeIDs { volumes.refreshSpace(of: volumeID) }
            }
        }
        lastCounters = current
        externalReadRate = externalRead
        externalWriteRate = externalWrite
        updateTimer()
        onSample?()
    }

    /// Bytes per second; zero before there are two samples.
    nonisolated static func rates(_ delta: IOCounters, over seconds: Double) -> (read: Double, write: Double) {
        guard seconds > 0 else { return (0, 0) }
        return (Double(delta.bytesRead) / seconds, Double(delta.bytesWritten) / seconds)
    }

    // MARK: - Timer

    /// 1 s while detailed, 5 s otherwise, none without external drives or
    /// while the display sleeps with no transfer running.
    nonisolated static func interval(hasExternal: Bool, detailed: Bool, displayAsleep: Bool, transferring: Bool) -> Int? {
        guard hasExternal else { return nil }
        if displayAsleep { return transferring ? 5 : nil }
        return detailed ? 1 : 5
    }

    private func updateTimer() {
        setTimer(Self.interval(
            hasExternal: drives.contains { $0.kind == .external },
            detailed: detailed,
            displayAsleep: displayAsleep,
            transferring: isTransferring
        ))
    }

    private func setTimer(_ seconds: Int?) {
        guard seconds != timerInterval else { return }
        timer?.cancel()
        timer = nil
        timerInterval = seconds
        guard let seconds else {
            lastSample = nil
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(seconds), repeating: .seconds(seconds), leeway: .milliseconds(seconds * 100))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.resume()
        self.timer = timer
    }

    private func observeSleep() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let pairs: [(NotificationCenter, Notification.Name, Bool)] = [
            (workspace, NSWorkspace.screensDidSleepNotification, true),
            (workspace, NSWorkspace.screensDidWakeNotification, false),
            (distributed, Notification.Name("com.apple.screenIsLocked"), true),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), false),
        ]
        for (center, name, asleep) in pairs {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.displayAsleep = asleep
                    // Read once on wake so rates and totals catch up.
                    if !asleep { self.sample() }
                    self.updateTimer()
                }
            }
            observers.append((center, observer))
        }
    }
}
