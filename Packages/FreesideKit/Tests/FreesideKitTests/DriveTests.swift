import Foundation
import Testing
@testable import FreesideKit

@Suite struct IOMathTests {
    @Test func countersSince() {
        let earlier = IOCounters(bytesRead: 100, bytesWritten: 1000)
        let later = IOCounters(bytesRead: 350, bytesWritten: 1000)
        #expect(later.since(earlier) == IOCounters(bytesRead: 250, bytesWritten: 0))
    }

    @Test func counterThatWentBackwardsCountsAsZero() {
        let earlier = IOCounters(bytesRead: 500, bytesWritten: 500)
        let restarted = IOCounters(bytesRead: 10, bytesWritten: 900)
        #expect(restarted.since(earlier) == IOCounters(bytesRead: 0, bytesWritten: 400))
    }

    @Test func rates() {
        let (read, write) = DriveMonitor.rates(IOCounters(bytesRead: 5_000_000, bytesWritten: 1_000_000), over: 5)
        #expect(read == 1_000_000)
        #expect(write == 200_000)
        #expect(DriveMonitor.rates(IOCounters(bytesRead: 1, bytesWritten: 1), over: 0) == (0, 0))
    }

    @Test(arguments: [
        // hasExternal, detailed, asleep, transferring → seconds
        (false, true, false, false, nil),
        (true, true, false, false, 1),
        (true, false, false, false, 5),
        (true, true, true, false, nil),
        (true, true, true, true, 5),
        (false, false, true, true, nil),
    ] as [(Bool, Bool, Bool, Bool, Int?)])
    func timerPolicy(hasExternal: Bool, detailed: Bool, asleep: Bool, transferring: Bool, expected: Int?) {
        #expect(DriveMonitor.interval(hasExternal: hasExternal, detailed: detailed, displayAsleep: asleep, transferring: transferring) == expected)
    }
}

/// The physical whole disk under a mounted volume, according to diskutil.
func physicalWholeDisk(of mountPath: String) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    process.arguments = ["info", "-plist", mountPath]
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let info = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    if let stores = info["APFSPhysicalStores"] as? [[String: Any]], let store = stores.first?["APFSPhysicalStore"] as? String {
        return store.replacing(/s\d+$/, with: "")
    }
    return try #require(info["ParentWholeDisk"] as? String)
}

extension DiskImageTests {
    @Suite @MainActor struct DeviceMapDiskImageTests {
        @Test(arguments: ["HFS+", "APFS", "ExFAT"])
        func volumeMapsToTheImageDisk(fileSystem: String) async throws {
            let image = try TestDiskImage(fileSystem: fileSystem, megabytes: 40)
            try image.attach()
            defer { try? image.detach() }

            var fs = statfs()
            #expect(statfs(image.mountPath, &fs) == 0)
            let volumeBSD = withUnsafeBytes(of: fs.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }.replacing("/dev/", with: "")

            let devices = DeviceMap.devices(forBSDName: volumeBSD)
            #expect(devices.count == 1)
            #expect(devices.first?.bsdName == (try physicalWholeDisk(of: image.mountPath)))
        }

        @Test func writesShowUpInTheCounters() async throws {
            let image = try TestDiskImage(megabytes: 60)
            try image.attach()
            defer { try? image.detach() }

            let volumeBSD = try #require(VolumeStore.mountedFileSystems().first { $0.path == image.mountPath }?.source).replacing("/dev/", with: "")
            let device = try #require(DeviceMap.devices(forBSDName: volumeBSD).first)
            let driver = try #require(BlockDriver(device))
            let before = try #require(driver.counters())

            let file = URL(fileURLWithPath: image.mountPath).appending(path: "data")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            try handle.write(contentsOf: Data(repeating: 7, count: 20_000_000))
            try handle.synchronize()
            try handle.close()

            let after = try #require(driver.counters())
            #expect(after.since(before).bytesWritten >= 20_000_000)
        }

        @Test func appleRAIDVolumeMapsToEachMember() async throws {
            // Two blank images striped into one AppleRAID volume.
            let directory = FileManager.default.temporaryDirectory.appending(path: "FreesideRAID\(Int.random(in: 10000...99999))")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            var members: [String] = []
            defer { for disk in members { try? TestDiskImage.run("/usr/bin/hdiutil", "detach", "-force", "-quiet", disk) } }
            for index in 0..<2 {
                let file = directory.appending(path: "member\(index).dmg")
                try TestDiskImage.run("/usr/bin/hdiutil", "create", "-size", "200m", "-layout", "NONE", "-quiet", file.path)
                members.append(try attachWithoutMounting(file))
            }
            let name = "FreesideRAID\(Int.random(in: 10000...99999))"
            try TestDiskImage.run("/usr/sbin/diskutil", "appleRAID", "create", "stripe", name, "JHFS+", members[0], members[1])
            defer { try? TestDiskImage.run("/usr/sbin/diskutil", "unmount", "force", "/Volumes/\(name)") }

            let volumeBSD = try #require(VolumeStore.mountedFileSystems().first { $0.path == "/Volumes/\(name)" }?.source).replacing("/dev/", with: "")
            let devices = DeviceMap.devices(forBSDName: volumeBSD)
            #expect(devices.map(\.bsdName).sorted() == members.sorted())
        }

        private func attachWithoutMounting(_ file: URL) throws -> String {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = ["attach", "-nomount", "-nobrowse", file.path]
            process.standardOutput = pipe
            try process.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let device = try #require(output.split(separator: "\n").first?.split(separator: " ").first)
            return String(device).replacing("/dev/", with: "")
        }
    }
}

extension DiskImageTests {
    @Suite @MainActor struct DriveMonitorDiskImageTests {
        @Test func imageGetsADriveWithRatesAndTotals() async throws {
            let image = try TestDiskImage(megabytes: 60)
            let volumes = VolumeStore()
            let monitor = DriveMonitor(volumes: volumes)
            volumes.start()
            monitor.start()
            defer {
                monitor.stop()
                volumes.stop()
            }
            try image.attach()
            defer { try? image.detach() }

            let found = await wait {
                guard let volume = volumes.volumes.first(where: { $0.mountPath == image.mountPath }) else { return false }
                return monitor.drives.contains { $0.volumeIDs.contains(volume.id) }
            }
            #expect(found != nil)
            let volumeID = try #require(volumes.volumes.first { $0.mountPath == image.mountPath }?.id)
            let drive = try #require(monitor.drives.first { $0.volumeIDs.contains(volumeID) })
            #expect(drive.kind == .diskImage)
            #expect(drive.members.count == 1)

            monitor.sample()
            let file = URL(fileURLWithPath: image.mountPath).appending(path: "data")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            try handle.write(contentsOf: Data(repeating: 7, count: 20_000_000))
            try handle.synchronize()
            try handle.close()
            try await Task.sleep(for: .milliseconds(300))
            monitor.sample()

            let sampled = try #require(monitor.drives.first { $0.id == drive.id })
            #expect((sampled.writeRate ?? 0) > 0)
            #expect(sampled.session.bytesWritten >= 20_000_000)
            #expect(sampled.writeTrace.last > 0)
        }
    }
}
