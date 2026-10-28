import Foundation
import Testing
@testable import FreesideKit

/// A disk image created and attached for one test. Attached without
/// `nobrowse`, so it's a visible volume like a real drive.
final class TestDiskImage {
    let name: String
    let file: URL
    var mountPath: String { "/Volumes/\(name)" }
    /// The image's whole disk once attached: "disk10".
    private(set) var disk: String?

    /// A sparse image grows as it's written, so an APFS image can be large
    /// enough for several volumes (about 512 MiB each) without taking the space.
    init(fileSystem: String = "HFS+", megabytes: Int = 20, sparse: Bool = false, in directory: URL? = nil) throws {
        // ExFAT volume names are limited to 11 characters.
        name = "FSTest\(Int.random(in: 10000...99999))"
        file = (directory ?? FileManager.default.temporaryDirectory).appending(path: "\(name).\(sparse ? "sparseimage" : "dmg")")
        var arguments = ["create", "-size", "\(megabytes)m", "-fs", fileSystem, "-volname", name, "-ov", "-quiet"]
        if sparse { arguments += ["-type", "SPARSE"] }
        try Self.run("/usr/bin/hdiutil", arguments + [file.path])
    }

    /// `diskutil image attach` uses DiskImages2, `hdiutil attach` the older
    /// IOHDIX driver; freeside has to handle both.
    func attachWithDiskutil() throws {
        try Self.run("/usr/sbin/diskutil", "image", "attach", file.path)
        let info = try Self.output("/usr/sbin/diskutil", "info", "-plist", mountPath)
        let plist = try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any]
        disk = plist?["ParentWholeDisk"] as? String
    }

    func attach() throws {
        let output = try Self.output("/usr/bin/hdiutil", "attach", "-plist", file.path)
        let plist = try PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any]
        let entities = plist?["system-entities"] as? [[String: Any]] ?? []
        // The first whole disk listed is the image's own; an APFS container comes after it.
        disk = entities.compactMap { ($0["dev-entry"] as? String)?.replacing("/dev/", with: "") }.first { $0.wholeMatch(of: /disk\d+/) != nil }
    }

    /// Adds an APFS volume to the image's container; it mounts at /Volumes/<name>.
    func addAPFSVolume(_ volumeName: String) throws {
        try Self.run("/usr/sbin/diskutil", "apfs", "addVolume", try container(), "APFS", volumeName)
    }

    func container() throws -> String {
        let info = try Self.output("/usr/sbin/diskutil", "info", "-plist", mountPath)
        let plist = try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any]
        guard let container = plist?["ParentWholeDisk"] as? String else { throw CocoaError(.fileNoSuchFile) }
        return container
    }

    var isAttached: Bool {
        guard let disk else { return false }
        return FileManager.default.fileExists(atPath: "/dev/\(disk)")
    }

    func detach() throws {
        try Self.run("/usr/bin/hdiutil", "detach", "-quiet", "-force", mountPath)
    }

    func rename(to newName: String) throws {
        try Self.run("/usr/sbin/diskutil", "rename", mountPath, newName)
    }

    deinit {
        // Best effort: the image may already be detached, or renamed.
        if isAttached, let disk { try? Self.run("/usr/bin/hdiutil", "detach", "-quiet", "-force", disk) }
        let renamed = ((try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []).filter { $0.hasPrefix("Renamed\(name.suffix(5))") }
        for path in [mountPath] + renamed.map({ "/Volumes/\($0)" }) {
            if FileManager.default.fileExists(atPath: path) { try? Self.run("/usr/bin/hdiutil", "detach", "-quiet", "-force", path) }
        }
        try? FileManager.default.removeItem(at: file)
    }

    static func run(_ tool: String, _ arguments: String...) throws {
        try run(tool, arguments)
    }

    static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "\(tool) \(arguments.joined(separator: " ")) exited \(process.terminationStatus)"])
        }
    }

    static func output(_ tool: String, _ arguments: String...) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "\(tool) \(arguments.joined(separator: " ")) exited \(process.terminationStatus)"])
        }
        return data
    }
}

/// Waits for `condition`, returning how long it took, or nil after `timeout`.
@MainActor
func wait(upTo timeout: Duration = .seconds(5), for condition: () -> Bool) async -> Duration? {
    let clock = ContinuousClock()
    let start = clock.now
    while clock.now - start < timeout {
        if condition() { return clock.now - start }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return nil
}

/// Every test that attaches disk images, run one at a time: attaching and
/// creating images in parallel slows mounts enough to break timing checks.
@Suite(.serialized) enum DiskImageTests {}

extension DiskImageTests {
    @Suite @MainActor struct VolumeStoreDiskImageTests {
        @Test func mountAndUnmountShowUpWithinASecond() async throws {
            let image = try TestDiskImage()
            let store = VolumeStore()
            store.start()
            defer { store.stop() }

            // The attach itself takes a while; time from the mount appearing in
            // the kernel's table to the store having it.
            try image.attach()
            let mounted = Date()
            let appeared = await wait { store.volumes.contains { $0.mountPath == image.mountPath } }
            #expect(appeared != nil)
            #expect(Date().timeIntervalSince(mounted) < 1)

            let volume = try #require(store.volumes.first { $0.mountPath == image.mountPath })
            #expect(volume.name == image.name)
            #expect(volume.kind == .diskImage)
            #expect(volume.format == "HFS+")
            #expect(volume.bsdName?.hasPrefix("disk") == true)
            #expect(!volume.isBoot)

            try image.detach()
            let unmounted = Date()
            let gone = await wait { !store.volumes.contains { $0.mountPath == image.mountPath } }
            #expect(gone != nil)
            #expect(Date().timeIntervalSince(unmounted) < 1)
        }

        @Test func readsSpaceOnMount() async throws {
            let image = try TestDiskImage(megabytes: 40)
            let store = VolumeStore()
            store.start()
            defer { store.stop() }
            try image.attach()
            defer { try? image.detach() }

            let read = await wait { store.volumes.first { $0.mountPath == image.mountPath }?.space != nil }
            #expect(read != nil)
            let space = try #require(store.volumes.first { $0.mountPath == image.mountPath }?.space)

            var fs = statfs()
            #expect(statfs(image.mountPath, &fs) == 0)
            #expect(space.total == Int64(fs.f_blocks) * Int64(fs.f_bsize))
            #expect(space.total > 30_000_000 && space.total <= 40 * 1_048_576)
            #expect(!space.isStale)
        }

        @Test func refreshSeesNewWrites() async throws {
            let image = try TestDiskImage(megabytes: 40)
            let store = VolumeStore()
            store.start()
            defer { store.stop() }
            try image.attach()
            defer { try? image.detach() }

            _ = await wait { store.volumes.first { $0.mountPath == image.mountPath }?.space != nil }
            let before = try #require(store.volumes.first { $0.mountPath == image.mountPath }?.space?.available)

            try Data(count: 10_000_000).write(to: URL(fileURLWithPath: image.mountPath).appending(path: "fill"))
            let id = try #require(store.volumes.first { $0.mountPath == image.mountPath }?.id)
            store.refreshSpace(of: id)
            let dropped = await wait { (store.volumes.first { $0.id == id }?.space?.available ?? before) < before - 9_000_000 }
            #expect(dropped != nil, "a refresh must not return a cached value")
        }

        @Test func renameKeepsTheVolume() async throws {
            let image = try TestDiskImage()
            let store = VolumeStore()
            store.start()
            defer { store.stop() }
            try image.attach()

            _ = await wait { store.volumes.contains { $0.mountPath == image.mountPath } }
            let id = try #require(store.volumes.first { $0.mountPath == image.mountPath }?.id)

            let newName = "Renamed\(image.name.suffix(5))"
            try image.rename(to: newName)
            let renamed = await wait { store.volumes.first { $0.id == id }?.name == newName }
            #expect(renamed != nil)
            #expect(store.volumes.first { $0.id == id }?.mountPath == "/Volumes/\(newName)")

            try TestDiskImage.run("/usr/bin/hdiutil", "detach", "-quiet", "-force", "/Volumes/\(newName)")
        }
    }
}
