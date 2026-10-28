import Foundation
import Testing
@testable import FreesideKit

/// A disk image created and attached for one test. Attached without
/// `nobrowse`, so it's a visible volume like a real drive.
final class TestDiskImage {
    let name: String
    let file: URL
    var mountPath: String { "/Volumes/\(name)" }

    init(fileSystem: String = "HFS+", megabytes: Int = 20) throws {
        // ExFAT volume names are limited to 11 characters.
        name = "FSTest\(Int.random(in: 10000...99999))"
        file = FileManager.default.temporaryDirectory.appending(path: "\(name).dmg")
        try Self.run("/usr/bin/hdiutil", "create", "-size", "\(megabytes)m", "-fs", fileSystem, "-volname", name, "-ov", "-quiet", file.path)
    }

    func attach() throws {
        try Self.run("/usr/bin/hdiutil", "attach", "-quiet", file.path)
    }

    func detach() throws {
        try Self.run("/usr/bin/hdiutil", "detach", "-quiet", "-force", mountPath)
    }

    func rename(to newName: String) throws {
        try Self.run("/usr/sbin/diskutil", "rename", mountPath, newName)
    }

    deinit {
        // Best effort: the image may already be detached, or renamed.
        for path in [mountPath] + ((try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []).filter { $0.hasPrefix("Renamed\(name.suffix(5))") }.map { "/Volumes/\($0)" } {
            if FileManager.default.fileExists(atPath: path) { try? Self.run("/usr/bin/hdiutil", "detach", "-quiet", "-force", path) }
        }
        try? FileManager.default.removeItem(at: file)
    }

    static func run(_ tool: String, _ arguments: String...) throws {
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
