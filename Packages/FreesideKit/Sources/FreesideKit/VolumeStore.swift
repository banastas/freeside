import AppKit
import DiskArbitration
import Observation

/// The list of mounted volumes and their free space. Rebuilt only when
/// DiskArbitration (or, as a fallback, NSWorkspace) reports a mount, unmount
/// or rename; never polled.
@MainActor
@Observable
public final class VolumeStore {
    /// Sorted in popover order, then by name.
    public private(set) var volumes: [Volume] = []

    @ObservationIgnored private let reader: SpaceReader
    @ObservationIgnored private var session: DASession?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var rebuildScheduled = false
    @ObservationIgnored private var reading: Set<Volume.ID> = []
    @ObservationIgnored private var refreshTimer: DispatchSourceTimer?

    public init(reader: SpaceReader = SpaceReader()) {
        self.reader = reader
    }

    public func start() {
        guard session == nil, let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session
        DASessionSetDispatchQueue(session, .main)

        // The session calls back on the main queue, and stop() unregisters
        // before the store can go away, so an unretained pointer is safe.
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, diskAppearedOrDisappeared, context)
        DARegisterDiskDisappearedCallback(session, nil, diskAppearedOrDisappeared, context)
        let watched = [kDADiskDescriptionVolumePathKey, kDADiskDescriptionVolumeNameKey] as CFArray
        DARegisterDiskDescriptionChangedCallback(session, nil, watched, diskDescriptionChanged, context)

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRebuild() }
            })
        }
        rebuild()
    }

    public func stop() {
        setSpaceVisible(false)
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
        guard let session else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        DAUnregisterCallback(session, unsafeBitCast(diskAppearedOrDisappeared as DADiskAppearedCallback, to: UnsafeMutableRawPointer.self), context)
        DAUnregisterCallback(session, unsafeBitCast(diskDescriptionChanged as DADiskDescriptionChangedCallback, to: UnsafeMutableRawPointer.self), context)
        DASessionSetDispatchQueue(session, nil)
        self.session = nil
    }

    // MARK: - Space

    /// Reads free space again for every volume.
    public func refreshSpace() {
        for volume in volumes { refreshSpace(of: volume.id) }
    }

    public func refreshSpace(of id: Volume.ID) {
        guard let volume = volumes.first(where: { $0.id == id }), reading.insert(id).inserted else { return }
        let path = volume.mountPath
        Task {
            let space = await reader.read(path: path)
            finishRead(id: id, path: path, space: space)
        }
    }

    /// While space is on screen (popover open, or the menu bar's `space`
    /// style), it's read again every 30 s. Otherwise nothing runs.
    public func setSpaceVisible(_ visible: Bool) {
        if !visible {
            refreshTimer?.cancel()
            refreshTimer = nil
            return
        }
        guard refreshTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(3))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refreshSpace() }
        }
        timer.resume()
        refreshTimer = timer
    }

    private func finishRead(id: Volume.ID, path: String, space: Space?) {
        reading.remove(id)
        guard let index = volumes.firstIndex(where: { $0.id == id && $0.mountPath == path }) else { return }
        if let space {
            volumes[index].space = space
        } else if volumes[index].space?.isStale == false {
            volumes[index].space?.isStale = true
        }
    }

    // MARK: - Volume list

    fileprivate func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        // A mount fires several callbacks at once; rebuild once after them.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    private func rebuild() {
        rebuildScheduled = false
        let previous = Dictionary(volumes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var next = Self.mountedFileSystems().map { mount in
            var volume = makeVolume(mount)
            volume.space = previous[volume.id]?.space
            return volume
        }
        next.sort { ($0.kind, $0.name.localizedLowercase) < ($1.kind, $1.name.localizedLowercase) }
        if next != volumes { volumes = next }
        for volume in volumes where volume.space == nil { refreshSpace(of: volume.id) }
    }

    private func makeVolume(_ mount: Mount) -> Volume {
        let bsdName = mount.source.hasPrefix("/dev/") ? String(mount.source.dropFirst(5)) : nil
        let description = bsdName.flatMap(diskDescription) ?? [:]
        let facts = VolumeFacts(
            isLocal: mount.isLocal,
            isRoot: mount.path == "/",
            deviceModel: (description[kDADiskDescriptionDeviceModelKey as String] as? String)?.trimmingCharacters(in: .whitespaces),
            deviceInternal: description[kDADiskDescriptionDeviceInternalKey as String] as? Bool,
            mediaRemovable: description[kDADiskDescriptionMediaRemovableKey as String] as? Bool
        )
        let uuid = description[kDADiskDescriptionVolumeUUIDKey as String].flatMap { value -> String? in
            let object = value as CFTypeRef
            guard CFGetTypeID(object) == CFUUIDGetTypeID() else { return nil }
            return CFUUIDCreateString(nil, (object as! CFUUID)) as String
        }
        return Volume(
            id: uuid ?? mount.source,
            name: description[kDADiskDescriptionVolumeNameKey as String] as? String ?? (mount.path as NSString).lastPathComponent,
            mountPath: mount.path,
            bsdName: bsdName,
            kind: VolumeKind(facts),
            format: FormatName.from(fileSystemType: mount.type),
            deviceProtocol: description[kDADiskDescriptionDeviceProtocolKey as String] as? String,
            deviceModel: facts.deviceModel,
            isBoot: facts.isRoot,
            space: nil
        )
    }

    private func diskDescription(bsdName: String) -> [String: Any]? {
        guard let session, let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else { return nil }
        return DADiskCopyDescription(disk) as? [String: Any]
    }

    struct Mount: Equatable {
        var path: String
        /// `/dev/disk7s1`, or `//user@server/share` for network volumes.
        var source: String
        var type: String
        var isLocal: Bool
    }

    /// Visible mounts from the kernel's mount table: the same set as
    /// `FileManager.mountedVolumeURLs(…, options: .skipHiddenVolumes)`, but
    /// `MNT_NOWAIT` guarantees a dead network share can't block the call.
    nonisolated static func mountedFileSystems() -> [Mount] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&buffer, MNT_NOWAIT)
        guard let buffer, count > 0 else { return [] }
        defer { free(buffer) }
        return UnsafeBufferPointer(start: buffer, count: Int(count)).compactMap { fs in
            let path = cString(fs.f_mntonname)
            guard path == "/" || fs.f_flags & UInt32(MNT_DONTBROWSE) == 0 else { return nil }
            return Mount(path: path, source: cString(fs.f_mntfromname), type: cString(fs.f_fstypename), isLocal: fs.f_flags & UInt32(MNT_LOCAL) != 0)
        }
    }

    private nonisolated static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

private func diskAppearedOrDisappeared(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let store = Unmanaged<VolumeStore>.fromOpaque(context)
    MainActor.assumeIsolated { store.takeUnretainedValue().scheduleRebuild() }
}

private func diskDescriptionChanged(_ disk: DADisk, _ keys: CFArray, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let store = Unmanaged<VolumeStore>.fromOpaque(context)
    MainActor.assumeIsolated { store.takeUnretainedValue().scheduleRebuild() }
}
