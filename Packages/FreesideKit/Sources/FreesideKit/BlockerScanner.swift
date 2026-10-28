import AppKit
import Darwin
import IOKit

/// A process holding something open on a drive.
public struct Blocker: Identifiable, Sendable, Equatable {
    public enum Reason: String, Sendable {
        case openFile = "open file"
        case workingDirectory = "working directory"
        case mappedFile = "mapped file"
    }

    public struct Use: Sendable, Equatable {
        public var reason: Reason
        public var path: String
    }

    public let pid: pid_t
    public var id: pid_t { pid }
    /// The executable's file name: "zsh", "Lightroom Classic".
    public var processName: String
    public var executablePath: String?
    /// The app the process belongs to: itself, or the nearest ancestor
    /// that is a regular app, so a shell shows as Terminal.
    public var app: OwningApp?
    /// The process is itself an app or one of its helpers, so quitting the
    /// app is the way to stop it. A shell under Terminal is not: it's
    /// terminated on its own rather than quitting every Terminal window.
    public var isAppProcess: Bool
    public var uses: [Use]

    /// What the row shows: the app's name, or the process name.
    public var displayName: String { app?.name ?? processName }
}

public struct OwningApp: Sendable, Equatable {
    public let pid: pid_t
    public var name: String
    public var bundleIdentifier: String?
    public var bundlePath: String?
}

/// A disk image attached from a file on the drive. It blocks the eject but
/// shows up as `diskimagesiod`, if at all.
public struct ImageBlocker: Identifiable, Sendable, Equatable {
    /// The image file: "/Volumes/Media/Project.sparsebundle".
    public let imagePath: String
    /// The image's whole disk: "disk12".
    public let bsdName: String
    public var id: String { bsdName }
    public var fileName: String { (imagePath as NSString).lastPathComponent }
}

public struct BlockerReport: Sendable, Equatable {
    public var blockers: [Blocker]
    public var images: [ImageBlocker]
    /// The slower memory-region pass ran (nothing else was found).
    public var scannedMappedFiles: Bool
    public var processCount: Int
    public var duration: Duration

    public var isEmpty: Bool { blockers.isEmpty && images.isEmpty }
}

/// Which mounted file systems to look for, by device ID (`st_dev`, which is
/// `f_fsid.val[0]`) and by mount path.
public struct ScanTarget: Sendable, Equatable {
    public var devices: Set<UInt32>
    public var mountPaths: [String]

    public init(devices: Set<UInt32>, mountPaths: [String]) {
        self.devices = devices
        self.mountPaths = mountPaths
    }
}

/// Finds the current user's processes holding files on a set of volumes:
/// the same set `lsof +f` reports, without root. Runs only on demand.
public enum BlockerScanner {
    public static func scan(_ target: ScanTarget) async -> BlockerReport {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: scanNow(target))
            }
        }
    }

    /// Open files, working directories and executables first. Walking memory
    /// regions costs ~150–220 ms with ~550 processes, so it only runs when
    /// that first pass finds nothing.
    static func scanNow(_ target: ScanTarget) -> BlockerReport {
        let clock = ContinuousClock()
        let start = clock.now
        let pids = userPIDs()
        let images = attachedImages().filter { image in target.mountPaths.contains { isPath(image.imagePath, inside: $0) } }
        var blockers: [Blocker] = []
        for pid in pids {
            guard var blocker = blocker(pid, target, mappedFiles: false) else { continue }
            // diskimages-helper holds each image's file open. The image row
            // covers it, and terminating the helper would damage the image.
            blocker.uses.removeAll { use in images.contains { isPath(use.path, inside: $0.imagePath) } }
            if !blocker.uses.isEmpty { blockers.append(blocker) }
        }
        var scannedMappedFiles = false
        if blockers.isEmpty, images.isEmpty {
            scannedMappedFiles = true
            for pid in pids {
                if let blocker = blocker(pid, target, mappedFiles: true) { blockers.append(blocker) }
            }
        }
        blockers.sort { ($0.displayName.localizedLowercase, $0.pid) < ($1.displayName.localizedLowercase, $1.pid) }
        return BlockerReport(blockers: blockers, images: images, scannedMappedFiles: scannedMappedFiles, processCount: pids.count, duration: clock.now - start)
    }

    // MARK: - Processes

    static func userPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = buffer.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        let uid = getuid()
        return buffer.prefix(Int(max(count, 0))).filter { $0 > 0 && shortInfo($0)?.pbsi_uid == uid }
    }

    private static func shortInfo(_ pid: pid_t) -> proc_bsdshortinfo? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        return proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func blocker(_ pid: pid_t, _ target: ScanTarget, mappedFiles: Bool) -> Blocker? {
        let executable = executablePath(pid)
        var uses: [Blocker.Use] = []
        if mappedFiles {
            uses = mappedUses(pid, target)
        } else {
            uses = fileUses(pid, target)
            if let cwd = workingDirectory(pid), target.devices.contains(cwd.device) {
                uses.insert(Blocker.Use(reason: .workingDirectory, path: cwd.path), at: 0)
            }
            // The executable is mapped, so it never shows up as an open file.
            if let executable, target.mountPaths.contains(where: { isPath(executable, inside: $0) }) {
                uses.insert(Blocker.Use(reason: .mappedFile, path: executable), at: 0)
            }
        }
        guard !uses.isEmpty else { return nil }
        let name = executable.map { ($0 as NSString).lastPathComponent } ?? shortInfo(pid).map { cString($0.pbsi_comm) } ?? "pid \(pid)"
        let app = owningApp(pid)
        let isAppProcess = app != nil && NSRunningApplication(processIdentifier: pid) != nil
        return Blocker(pid: pid, processName: name, executablePath: executable, app: app, isAppProcess: isAppProcess, uses: uses)
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func workingDirectory(_ pid: pid_t) -> (path: String, device: UInt32)? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return (cString(info.pvi_cdir.vip_path), info.pvi_cdir.vip_vi.vi_stat.vst_dev)
    }

    private static func fileUses(_ pid: pid_t, _ target: ScanTarget) -> [Blocker.Use] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Room for descriptors opened between the two calls.
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }

        var uses: [Blocker.Use] = []
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size,
                  target.devices.contains(info.pvip.vip_vi.vi_stat.vst_dev),
                  // FSEvents and kqueue watchers don't block an unmount.
                  info.pfi.fi_openflags & UInt32(O_EVTONLY) == 0
            else { continue }
            uses.append(Blocker.Use(reason: .openFile, path: cString(info.pvip.vip_path)))
        }
        return uses
    }

    /// `PROC_PIDREGIONPATHINFO2` (private; `vmmap` and `lsof` use it) returns
    /// only file-backed regions, about 40 per process instead of ~1,800.
    private static let regionPathInfo2: Int32 = 22

    private static func mappedUses(_ pid: pid_t, _ target: ScanTarget) -> [Blocker.Use] {
        var uses: [Blocker.Use] = []
        var seen: Set<String> = []
        var address: UInt64 = 0
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        for _ in 0..<100_000 {
            var info = proc_regionwithpathinfo()
            guard proc_pidinfo(pid, regionPathInfo2, address, &info, size) == size else { break }
            if target.devices.contains(info.prp_vip.vip_vi.vi_stat.vst_dev) {
                let path = cString(info.prp_vip.vip_path)
                if seen.insert(path).inserted { uses.append(Blocker.Use(reason: .mappedFile, path: path)) }
            }
            let next = info.prp_prinfo.pri_address + info.prp_prinfo.pri_size
            guard next > address else { break }
            address = next
        }
        return uses
    }

    /// The process itself if it's a regular app, otherwise the nearest
    /// ancestor that is (a shell's Terminal), otherwise whatever
    /// NSRunningApplication knows about the process (an agent or helper).
    private static func owningApp(_ pid: pid_t) -> OwningApp? {
        var current = pid
        for _ in 0..<32 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                return OwningApp(app)
            }
            guard let parent = shortInfo(current)?.pbsi_ppid, parent > 1, pid_t(parent) != current else { break }
            current = pid_t(parent)
        }
        return NSRunningApplication(processIdentifier: pid).flatMap(OwningApp.init)
    }

    // MARK: - Disk images

    /// Every attached disk image, with its backing file and whole disk.
    /// Two drivers serve images: `hdiutil attach` still uses the older
    /// IOHDIX one (`image-path`, bytes), while `diskutil image attach` uses
    /// DiskImages2's `AppleDiskImageDevice` (`DiskImageURL`, a file URL string).
    static func attachedImages() -> [ImageBlocker] {
        images(of: "IOHDIXHDDriveOutKernel") { drive in
            (DeviceMap.property(drive, "image-path") as? Data).map { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        } + images(of: "AppleDiskImageDevice") { drive in
            (DeviceMap.property(drive, "DiskImageURL") as? String).flatMap(URL.init(string:)).map(\.path)
        }
    }

    private static func images(of driverClass: String, path: (io_registry_entry_t) -> String?) -> [ImageBlocker] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(driverClass), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var images: [ImageBlocker] = []
        while case let drive = IOIteratorNext(iterator), drive != 0 {
            defer { IOObjectRelease(drive) }
            guard let imagePath = path(drive), let bsdName = wholeDisk(under: drive) else { continue }
            images.append(ImageBlocker(imagePath: imagePath, bsdName: bsdName))
        }
        return images
    }

    private static func wholeDisk(under entry: io_registry_entry_t) -> String? {
        var children: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(entry, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &children) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(children) }
        while case let child = IOIteratorNext(children), child != 0 {
            defer { IOObjectRelease(child) }
            if IOObjectConformsTo(child, "IOMedia") != 0, DeviceMap.property(child, "Whole") as? Bool == true,
               let name = DeviceMap.property(child, kIOBSDNameKey) as? String {
                return name
            }
        }
        return nil
    }

    // MARK: - Helpers

    static func isPath(_ path: String, inside mountPath: String) -> Bool {
        if mountPath == "/" { return path.hasPrefix("/") }
        return path == mountPath || path.hasPrefix(mountPath + "/")
    }

    private static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

extension OwningApp {
    init?(_ app: NSRunningApplication) {
        guard let name = app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent else { return nil }
        self.init(pid: app.processIdentifier, name: name, bundleIdentifier: app.bundleIdentifier, bundlePath: app.bundleURL?.path)
    }
}
