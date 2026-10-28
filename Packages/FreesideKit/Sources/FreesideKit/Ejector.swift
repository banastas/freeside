import AppKit
import DiskArbitration
import IOKit
import Observation

/// Something to eject: a drive's physical disks, or one network volume.
public struct EjectTarget: Identifiable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var kind: VolumeKind
    /// Physical whole disks. Empty for a network volume.
    public var members: [BlockDevice]
    /// A network volume's mount path.
    public var networkMountPath: String?

    public init(drive: Drive) {
        id = drive.id
        name = drive.name
        kind = drive.kind
        members = drive.members
    }

    public init(networkVolume volume: Volume) {
        id = volume.id
        name = volume.name
        kind = volume.kind
        members = []
        networkMountPath = volume.mountPath
    }

    /// Every file system mounted from the target, hidden ones included.
    func mounts() -> [VolumeStore.Mount] {
        let all = VolumeStore.mountedFileSystems(includeHidden: true)
        if let networkMountPath { return all.filter { $0.path == networkMountPath } }
        let driverIDs = Set(members.map(\.driverID))
        return all.filter { mount in
            guard mount.source.hasPrefix("/dev/") else { return false }
            return DeviceMap.devices(forBSDName: String(mount.source.dropFirst(5))).contains { driverIDs.contains($0.driverID) }
        }
    }

    func scanTarget(_ mounts: [VolumeStore.Mount]) -> ScanTarget {
        ScanTarget(devices: Set(mounts.map(\.device)), mountPaths: mounts.map(\.path))
    }
}

/// Why an unmount or eject didn't happen.
public enum EjectFailure: Sendable, Equatable {
    /// Files are open on the volume: the Blockers panel's case.
    case busy
    /// Another app refused the unmount.
    case notPermitted(by: String?)
    /// A process has the device open exclusively (Disk Utility, say).
    case exclusiveAccess
    case other(status: Int32, message: String?)

    static func from(status: Int32, message: String?) -> EjectFailure {
        switch UInt32(bitPattern: status) {
        // What DiskArbitration actually returns for a volume in use is
        // unix_err(EBUSY), not kDAReturnBusy (PRD §15).
        case 0x0000_C010, 0xF8DA_0002: .busy
        case 0xF8DA_0008: .notPermitted(by: message)
        case 0xF8DA_0004: .exclusiveAccess
        default: .other(status: status, message: message)
        }
    }

    public var message: String {
        switch self {
        case .busy: "Files on the drive are in use."
        case .notPermitted(let app): app.map { "\($0) refused to let the drive eject." } ?? "Another app refused to let the drive eject."
        case .exclusiveAccess: "Another app, such as Disk Utility, is using the drive exclusively."
        case .other(let status, let message):
            [message, String(format: "Error 0x%08X", UInt32(bitPattern: status))].compactMap(\.self).joined(separator: ". ")
        }
    }
}

/// DiskArbitration's asynchronous unmount and eject, awaited.
final class DiskArbitrationClient: Sendable {
    struct Dissent: Sendable, Equatable {
        var status: Int32
        var message: String?
    }

    static let shared = DiskArbitrationClient()

    private nonisolated(unsafe) let session: DASession?
    private let queue = DispatchQueue(label: "as.banast.freeside.eject")

    init() {
        session = DASessionCreate(kCFAllocatorDefault)
        if let session { DASessionSetDispatchQueue(session, queue) }
    }

    func unmount(bsdName: String, whole: Bool, force: Bool) async -> Dissent? {
        guard let session, let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else {
            return Dissent(status: Int32(bitPattern: 0xF8DA_0006), message: "\(bsdName) not found")
        }
        return await unmount(disk, whole: whole, force: force)
    }

    func unmount(volumePath: String, force: Bool) async -> Dissent? {
        guard let session, let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, URL(fileURLWithPath: volumePath) as CFURL) else {
            return Dissent(status: Int32(bitPattern: 0xF8DA_0006), message: "\(volumePath) not found")
        }
        return await unmount(disk, whole: false, force: force)
    }

    func eject(bsdName: String) async -> Dissent? {
        guard let session, let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else {
            return Dissent(status: Int32(bitPattern: 0xF8DA_0006), message: "\(bsdName) not found")
        }
        return await withCheckedContinuation { continuation in
            DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), ejectFinished, Completion(continuation).retained())
        }
    }

    /// The whole disk a volume's disk belongs to: "disk7" for "disk7s1".
    func wholeDisk(of bsdName: String) -> String? {
        guard let session, let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName),
              let whole = DADiskCopyWholeDisk(disk), let name = DADiskGetBSDName(whole)
        else { return nil }
        return String(cString: name)
    }

    private func unmount(_ disk: DADisk, whole: Bool, force: Bool) async -> Dissent? {
        var options = kDADiskUnmountOptionDefault
        if whole { options |= kDADiskUnmountOptionWhole }
        if force { options |= kDADiskUnmountOptionForce }
        let unmountOptions = DADiskUnmountOptions(options)
        return await withCheckedContinuation { continuation in
            DADiskUnmount(disk, unmountOptions, unmountFinished, Completion(continuation).retained())
        }
    }
}

private final class Completion: @unchecked Sendable {
    let continuation: CheckedContinuation<DiskArbitrationClient.Dissent?, Never>

    init(_ continuation: CheckedContinuation<DiskArbitrationClient.Dissent?, Never>) {
        self.continuation = continuation
    }

    func retained() -> UnsafeMutableRawPointer { Unmanaged.passRetained(self).toOpaque() }

    static func finish(_ dissenter: DADissenter?, _ context: UnsafeMutableRawPointer?) {
        guard let context else { return }
        let completion = Unmanaged<Completion>.fromOpaque(context).takeRetainedValue()
        completion.continuation.resume(returning: dissenter.map {
            DiskArbitrationClient.Dissent(status: DADissenterGetStatus($0), message: DADissenterGetStatusString($0) as String?)
        })
    }
}

private func unmountFinished(_ disk: DADisk, _ dissenter: DADissenter?, _ context: UnsafeMutableRawPointer?) {
    Completion.finish(dissenter, context)
}

private func ejectFinished(_ disk: DADisk, _ dissenter: DADissenter?, _ context: UnsafeMutableRawPointer?) {
    Completion.finish(dissenter, context)
}

/// Ejects drives in Finder's order, and when an eject fails as busy, finds
/// what's holding it.
@MainActor
@Observable
public final class Ejector {
    public enum Phase: Sendable, Equatable {
        case ejecting
        case scanning
        /// Finished, with a failure or a report to show.
        case idle
    }

    public struct Status: Sendable, Equatable {
        public var target: EjectTarget
        public var phase: Phase
        /// Nil after "Who's using this?", which doesn't eject.
        public var failure: EjectFailure?
        public var report: BlockerReport?
        /// Names of volumes still mounted after a failed eject.
        public var stillMounted: [String]
    }

    public struct EjectAllResult: Sendable, Equatable {
        public var ejected: [String]
        public var failed: [EjectTarget.ID]
    }

    /// Only targets with something to show: an eject in progress, a failure,
    /// or a blocker report. A successful eject removes its entry.
    public private(set) var statuses: [EjectTarget.ID: Status] = [:]

    @ObservationIgnored private let client: DiskArbitrationClient
    @ObservationIgnored private var exitSources: [EjectTarget.ID: [DispatchSourceProcess]] = [:]
    @ObservationIgnored private var waitingFor: [EjectTarget.ID: Set<pid_t>] = [:]
    @ObservationIgnored private var rescanTimers: [EjectTarget.ID: DispatchSourceTimer] = [:]

    init(client: DiskArbitrationClient) {
        self.client = client
    }

    public convenience init() {
        self.init(client: .shared)
    }

    // MARK: - Ejecting

    /// Unmounts every volume on the target, then ejects it. Returns true when
    /// it's gone; otherwise `statuses[target.id]` says why.
    @discardableResult
    public func eject(_ target: EjectTarget, force: Bool = false) async -> Bool {
        guard statuses[target.id]?.phase != .ejecting else { return false }
        stopWatching(target.id)
        statuses[target.id] = Status(target: target, phase: .ejecting, failure: nil, report: nil, stillMounted: [])
        let failure = await Self.perform(target, force: force, client: client)
        guard let failure else {
            statuses[target.id] = nil
            return true
        }
        let mounts = target.mounts()
        var status = Status(target: target, phase: .idle, failure: failure, report: nil, stillMounted: Self.names(mounts))
        if failure == .busy {
            status.phase = .scanning
            statuses[target.id] = status
            status.report = await BlockerScanner.scan(target.scanTarget(mounts))
            status.phase = .idle
            guard statuses[target.id]?.phase == .scanning else { return false }
            retryWhenBlockersExit(status)
        }
        statuses[target.id] = status
        return false
    }

    /// One at a time, carrying on past failures.
    public func ejectAll(_ targets: [EjectTarget]) async -> EjectAllResult {
        var result = EjectAllResult(ejected: [], failed: [])
        for target in targets {
            if await eject(target) { result.ejected.append(target.name) } else { result.failed.append(target.id) }
        }
        return result
    }

    /// Continues a failed eject from where it stopped.
    @discardableResult
    public func retry(_ id: EjectTarget.ID, force: Bool = false) async -> Bool {
        guard let target = statuses[id]?.target else { return false }
        return await eject(target, force: force)
    }

    /// "Who's using this?": a scan without ejecting.
    public func inspect(_ target: EjectTarget) async {
        guard statuses[target.id]?.phase != .ejecting else { return }
        let mounts = target.mounts()
        var status = statuses[target.id] ?? Status(target: target, phase: .scanning, failure: nil, report: nil, stillMounted: [])
        status.phase = .scanning
        statuses[target.id] = status
        status.report = await BlockerScanner.scan(target.scanTarget(mounts))
        status.stillMounted = Self.names(mounts)
        status.phase = .idle
        guard statuses[target.id] != nil else { return }
        statuses[target.id] = status
    }

    public func dismiss(_ id: EjectTarget.ID) {
        stopWatching(id)
        statuses[id] = nil
    }

    /// While the Blockers panel shows a target, rescan every 2 s.
    public func setWatching(_ id: EjectTarget.ID, _ watching: Bool) {
        rescanTimers[id]?.cancel()
        rescanTimers[id] = nil
        guard watching else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let status = self.statuses[id], status.phase == .idle else { return }
                Task { await self.rescan(id) }
            }
        }
        timer.resume()
        rescanTimers[id] = timer
    }

    private func rescan(_ id: EjectTarget.ID) async {
        guard var status = statuses[id] else { return }
        let mounts = status.target.mounts()
        status.report = await BlockerScanner.scan(status.target.scanTarget(mounts))
        status.stillMounted = Self.names(mounts)
        guard statuses[id]?.phase == .idle else { return }
        statuses[id] = status
        if status.failure != nil { retryWhenBlockersExit(status) }
    }

    // MARK: - Acting on blockers

    /// Asks the owning app to quit, so it can save and ask about unsaved
    /// work. Only for app processes; others are terminated.
    @discardableResult
    public func quit(_ blocker: Blocker) -> Bool {
        guard blocker.isAppProcess, let app = blocker.app, let running = NSRunningApplication(processIdentifier: app.pid) else { return false }
        return running.terminate()
    }

    /// SIGTERM, or SIGKILL with `kill`. The caller confirms first.
    @discardableResult
    public func terminate(_ blocker: Blocker, kill: Bool = false) -> Bool {
        Darwin.kill(blocker.pid, kill ? SIGKILL : SIGTERM) == 0
    }

    /// Ejects a disk image that's attached from a file on the drive.
    @discardableResult
    public func ejectImage(_ image: ImageBlocker, from id: EjectTarget.ID) async -> Bool {
        let failure = await Self.perform(Self.imageTarget(image), force: false, client: client)
        if failure == nil, statuses[id]?.phase == .idle { await rescan(id) }
        return failure == nil
    }

    // MARK: - Internals

    /// Unmounts, in this order: every synthesized whole disk on the target
    /// (APFS containers, an AppleRAID set), then each physical disk whole,
    /// then ejects each physical disk. Unmounting the physical disk alone
    /// leaves APFS volumes mounted (PRD §15).
    nonisolated static func perform(_ target: EjectTarget, force: Bool, client: DiskArbitrationClient) async -> EjectFailure? {
        if let path = target.networkMountPath {
            return await client.unmount(volumePath: path, force: force).map { EjectFailure.from(status: $0.status, message: $0.message) }
        }
        let members = target.members.map(\.bsdName)
        for disk in synthesizedWholeDisks(target, client: client) {
            if let dissent = await client.unmount(bsdName: disk, whole: true, force: force) {
                return EjectFailure.from(status: dissent.status, message: dissent.message)
            }
        }
        for disk in members {
            if let dissent = await client.unmount(bsdName: disk, whole: true, force: force) {
                return EjectFailure.from(status: dissent.status, message: dissent.message)
            }
        }
        for disk in members {
            if let dissent = await client.eject(bsdName: disk) {
                return EjectFailure.from(status: dissent.status, message: dissent.message)
            }
        }
        return nil
    }

    /// Whole disks that aren't physical members: those under each member in
    /// the registry (APFS containers), and the whole disks of mounted
    /// volumes (an AppleRAID set's disk). Deepest first.
    nonisolated static func synthesizedWholeDisks(_ target: EjectTarget, client: DiskArbitrationClient) -> [String] {
        let members = Set(target.members.map(\.bsdName))
        var disks: [String] = []
        for member in target.members {
            for disk in wholeDisks(under: member.bsdName).reversed() where !members.contains(disk) && !disks.contains(disk) {
                disks.append(disk)
            }
        }
        for mount in target.mounts() where mount.source.hasPrefix("/dev/") {
            if let whole = client.wholeDisk(of: String(mount.source.dropFirst(5))), !members.contains(whole), !disks.contains(whole) {
                disks.append(whole)
            }
        }
        return disks
    }

    /// Whole IOMedia below a disk, in registry order (parents first).
    private nonisolated static func wholeDisks(under bsdName: String) -> [String] {
        let media = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsdName))
        guard media != 0 else { return [] }
        defer { IOObjectRelease(media) }
        var children: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(media, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &children) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(children) }
        var disks: [String] = []
        while case let child = IOIteratorNext(children), child != 0 {
            defer { IOObjectRelease(child) }
            if IOObjectConformsTo(child, "IOMedia") != 0, DeviceMap.property(child, "Whole") as? Bool == true,
               let name = DeviceMap.property(child, kIOBSDNameKey) as? String {
                disks.append(name)
            }
        }
        return disks
    }

    private static func imageTarget(_ image: ImageBlocker) -> EjectTarget {
        let devices = DeviceMap.devices(forBSDName: image.bsdName)
        var drive = Drive(id: image.bsdName, name: image.fileName, deviceProtocol: nil, kind: .diskImage, members: devices, volumeIDs: [])
        if devices.isEmpty { drive.members = [BlockDevice(driverID: 0, bsdName: image.bsdName)] }
        return EjectTarget(drive: drive)
    }

    private static func names(_ mounts: [VolumeStore.Mount]) -> [String] {
        mounts.filter { !$0.isHidden }.map { ($0.path as NSString).lastPathComponent }
    }

    /// Retries on its own once every listed process has exited.
    private func retryWhenBlockersExit(_ status: Status) {
        let id = status.target.id
        exitSources[id]?.forEach { $0.cancel() }
        exitSources[id] = nil
        guard let blockers = status.report?.blockers, !blockers.isEmpty else { return }
        waitingFor[id] = Set(blockers.map(\.pid))
        exitSources[id] = blockers.map { blocker in
            let pid = blocker.pid
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.processExited(pid, blocking: id) }
            }
            source.resume()
            return source
        }
        // A process that exited before its source was set up never fires.
        for blocker in blockers where Darwin.kill(blocker.pid, 0) != 0 && errno == ESRCH {
            processExited(blocker.pid, blocking: id)
        }
    }

    private func processExited(_ pid: pid_t, blocking id: EjectTarget.ID) {
        guard var waiting = waitingFor[id], waiting.remove(pid) != nil else { return }
        waitingFor[id] = waiting
        guard waiting.isEmpty, statuses[id]?.phase == .idle else { return }
        waitingFor[id] = nil
        Task { await retryAfterExit(id) }
    }

    /// The exit can be reported a moment before the kernel lets go of the
    /// process's files, so a retry that fails with nothing left to blame
    /// tries again shortly. One that finds new blockers waits for them instead.
    private func retryAfterExit(_ id: EjectTarget.ID) async {
        for attempt in 1...3 {
            if await retry(id) { return }
            guard let status = statuses[id], status.failure == .busy, status.report?.isEmpty == true, attempt < 3 else { return }
            try? await Task.sleep(for: .seconds(1))
            guard statuses[id]?.phase == .idle else { return }
        }
    }

    private func stopWatching(_ id: EjectTarget.ID) {
        exitSources[id]?.forEach { $0.cancel() }
        exitSources[id] = nil
        waitingFor[id] = nil
        rescanTimers[id]?.cancel()
        rescanTimers[id] = nil
    }
}
