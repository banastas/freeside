import AppKit
import Foundation
import Testing
@testable import FreesideKit

struct EjectFailureTests {
    @Test func statuses() {
        #expect(EjectFailure.from(status: 0xC010, message: nil) == .busy)
        #expect(EjectFailure.from(status: Int32(bitPattern: 0xF8DA_0002), message: nil) == .busy)
        #expect(EjectFailure.from(status: Int32(bitPattern: 0xF8DA_0008), message: "Photos") == .notPermitted(by: "Photos"))
        #expect(EjectFailure.from(status: Int32(bitPattern: 0xF8DA_0004), message: nil) == .exclusiveAccess)
        #expect(EjectFailure.from(status: 5, message: "I/O error") == .other(status: 5, message: "I/O error"))
        #expect(EjectFailure.other(status: 5, message: "I/O error").message == "I/O error. Error 0x00000005")
    }

    @Test func pathsInsideAMount() {
        #expect(BlockerScanner.isPath("/Volumes/A/file", inside: "/Volumes/A"))
        #expect(BlockerScanner.isPath("/Volumes/A", inside: "/Volumes/A"))
        #expect(!BlockerScanner.isPath("/Volumes/AB/file", inside: "/Volumes/A"))
    }
}

/// The volume's BSD name and device ID, from the mount table.
func mount(at path: String) throws -> VolumeStore.Mount {
    try #require(VolumeStore.mountedFileSystems(includeHidden: true).first { $0.path == path })
}

func scanTarget(_ paths: String...) throws -> ScanTarget {
    let mounts = try paths.map(mount(at:))
    return ScanTarget(devices: Set(mounts.map(\.device)), mountPaths: mounts.map(\.path))
}

func ejectTarget(for image: TestDiskImage) throws -> EjectTarget {
    let bsdName = try mount(at: image.mountPath).source.replacing("/dev/", with: "")
    let members = DeviceMap.devices(forBSDName: bsdName)
    try #require(!members.isEmpty)
    return EjectTarget(drive: Drive(id: members.map { String($0.driverID) }.joined(separator: "+"), name: image.name, kind: .diskImage, members: members, volumeIDs: []))
}

/// A child process with its working directory on the volume.
func sleeper(in directory: String, executable: String = "/bin/sleep") throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["60"]
    process.currentDirectoryURL = URL(fileURLWithPath: directory)
    try process.run()
    return process
}

extension DiskImageTests {
    @Suite @MainActor struct BlockerScannerDiskImageTests {
        @Test func deviceIDMatchesStat() throws {
            let image = try TestDiskImage()
            try image.attach()
            var info = stat()
            #expect(stat(image.mountPath, &info) == 0)
            #expect(try mount(at: image.mountPath).device == UInt32(bitPattern: info.st_dev))
        }

        @Test func findsOpenFilesAndWorkingDirectories() async throws {
            let image = try TestDiskImage()
            try image.attach()
            let path = image.mountPath + "/open.txt"
            FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
            let handle = try #require(FileHandle(forReadingAtPath: path))
            defer { try? handle.close() }
            let child = try sleeper(in: image.mountPath)
            defer { child.terminate() }

            let report = await BlockerScanner.scan(try scanTarget(image.mountPath))
            let me = try #require(report.blockers.first { $0.pid == getpid() })
            #expect(me.uses.contains(Blocker.Use(reason: .openFile, path: path)))
            let sleeper = try #require(report.blockers.first { $0.pid == child.processIdentifier })
            #expect(sleeper.uses == [Blocker.Use(reason: .workingDirectory, path: image.mountPath)])
            #expect(sleeper.processName == "sleep")
            #expect(!report.scannedMappedFiles)
        }

        @Test func skipsEventOnlyDescriptors() async throws {
            let image = try TestDiskImage()
            try image.attach()
            let fd = open(image.mountPath, O_EVTONLY)
            #expect(fd >= 0)
            defer { close(fd) }

            let report = await BlockerScanner.scan(try scanTarget(image.mountPath))
            #expect(!report.blockers.contains { $0.pid == getpid() })
        }

        @Test func findsAnExecutableRunningFromTheVolume() async throws {
            let image = try TestDiskImage()
            try image.attach()
            let copy = image.mountPath + "/sleep"
            try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: copy)
            let child = try sleeper(in: "/", executable: copy)
            defer { child.terminate() }

            let report = await BlockerScanner.scan(try scanTarget(image.mountPath))
            let blocker = try #require(report.blockers.first { $0.pid == child.processIdentifier })
            #expect(blocker.uses == [Blocker.Use(reason: .mappedFile, path: copy)])
        }

        @Test func findsAMappedFileWithNoDescriptor() async throws {
            let image = try TestDiskImage()
            try image.attach()
            let path = image.mountPath + "/mapped"
            FileManager.default.createFile(atPath: path, contents: Data(repeating: 1, count: 65536))
            let fd = open(path, O_RDONLY)
            let mapped = mmap(nil, 65536, PROT_READ, MAP_SHARED, fd, 0)
            close(fd)
            #expect(mapped != MAP_FAILED)
            defer { munmap(mapped, 65536) }

            let report = await BlockerScanner.scan(try scanTarget(image.mountPath))
            #expect(report.scannedMappedFiles)
            let me = try #require(report.blockers.first { $0.pid == getpid() })
            #expect(me.uses == [Blocker.Use(reason: .mappedFile, path: path)])
        }

        @Test func listsAnImageAttachedFromTheVolume() async throws {
            let outer = try TestDiskImage(megabytes: 60)
            try outer.attach()
            let inner = try TestDiskImage(megabytes: 20, in: URL(fileURLWithPath: outer.mountPath))
            try inner.attach()
            let innerDisk = try #require(inner.disk)

            let report = await BlockerScanner.scan(try scanTarget(outer.mountPath))
            let row = try #require(report.images.first)
            #expect(report.images.count == 1)
            // The helper serving the image holds its file open; the image row covers it.
            #expect(!report.blockers.contains { $0.uses.contains { $0.path == row.imagePath } })
            #expect(row.bsdName == innerDisk)
            #expect(row.imagePath.hasSuffix("/\(inner.name).dmg"))

            // Ejecting the image from the Blockers panel detaches it.
            let ejector = Ejector()
            #expect(await ejector.ejectImage(row, from: "none"))
            #expect(!inner.isAttached)
        }

        @Test func listsAnImageAttachedWithDiskImages2() async throws {
            let outer = try TestDiskImage(megabytes: 60)
            try outer.attach()
            let inner = try TestDiskImage(megabytes: 20, in: URL(fileURLWithPath: outer.mountPath))
            try inner.attachWithDiskutil()
            let innerDisk = try #require(inner.disk)

            let report = await BlockerScanner.scan(try scanTarget(outer.mountPath))
            let row = try #require(report.images.first)
            #expect(report.images.count == 1)
            #expect(row.bsdName == innerDisk)
            #expect(row.imagePath.hasSuffix("/\(inner.name).dmg"))
        }

        /// freeside reads volume lists, space, icons and I/O counters, and
        /// must never be what holds a drive.
        @Test func freesideIsNeverAHolder() async throws {
            let image = try TestDiskImage()
            let volumes = VolumeStore()
            let drives = DriveMonitor(volumes: volumes)
            volumes.start()
            drives.start()
            defer {
                drives.stop()
                volumes.stop()
            }
            try image.attach()
            _ = await wait { volumes.volumes.first { $0.mountPath == image.mountPath }?.space != nil }
            volumes.refreshSpace()
            drives.sample()
            _ = NSWorkspace.shared.icon(forFile: image.mountPath)
            try await Task.sleep(for: .milliseconds(300))

            let report = await BlockerScanner.scan(try scanTarget(image.mountPath))
            #expect(report.scannedMappedFiles)
            #expect(!report.blockers.contains { $0.pid == getpid() })
        }

        /// PRD §8: under 100 ms with 600 processes, for the pass that runs
        /// whenever something holds the drive.
        @Test func scanCost() async throws {
            let image = try TestDiskImage()
            try image.attach()
            let child = try sleeper(in: image.mountPath)
            defer { child.terminate() }
            let target = try scanTarget(image.mountPath)

            var first: [Duration] = []
            for _ in 0..<5 { first.append(BlockerScanner.scanNow(target).duration) }
            let processes = BlockerScanner.userPIDs().count
            let fast = first.sorted()[2]
            print("blocker scan: \(processes) processes, median \(fast)")
            #expect(fast < .milliseconds(100))

            child.terminate()
            child.waitUntilExit()
            let slow = BlockerScanner.scanNow(target)
            print("blocker scan with mapped files: \(slow.duration)")
            #expect(slow.scannedMappedFiles)
        }
    }
}

extension DiskImageTests {
    @Suite @MainActor struct EjectorDiskImageTests {
        @Test func ejectsEveryAPFSVolumeOnTheDevice() async throws {
            let image = try TestDiskImage(fileSystem: "APFS", megabytes: 2048, sparse: true)
            try image.attach()
            let second = "FSTest\(Int.random(in: 10000...99999))"
            try image.addAPFSVolume(second)
            #expect(FileManager.default.fileExists(atPath: "/Volumes/\(second)"))
            let target = try ejectTarget(for: image)
            #expect(Ejector.synthesizedWholeDisks(target, client: .shared) == [try image.container()])

            let ejector = Ejector()
            #expect(await ejector.eject(target))
            #expect(ejector.statuses.isEmpty)
            let mounted = VolumeStore.mountedFileSystems(includeHidden: true).map(\.path)
            #expect(!mounted.contains(image.mountPath))
            #expect(!mounted.contains("/Volumes/\(second)"))
            #expect(!image.isAttached)
        }

        @Test func busyEjectListsBlockersAndRetries() async throws {
            let image = try TestDiskImage(fileSystem: "APFS", megabytes: 2048, sparse: true)
            try image.attach()
            let second = "FSTest\(Int.random(in: 10000...99999))"
            try image.addAPFSVolume(second)
            let path = "/Volumes/\(second)/open.txt"
            FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
            let handle = try #require(FileHandle(forReadingAtPath: path))
            let target = try ejectTarget(for: image)

            let ejector = Ejector()
            #expect(await ejector.eject(target) == false)
            let status = try #require(ejector.statuses[target.id])
            #expect(status.failure == .busy)
            #expect(status.phase == .idle)
            #expect(status.stillMounted.contains(second))
            // The volume that wasn't busy is already gone (PRD §6.2).
            #expect(!status.stillMounted.contains(image.name))
            let me = try #require(status.report?.blockers.first { $0.pid == getpid() })
            #expect(me.uses.contains(Blocker.Use(reason: .openFile, path: path)))

            try handle.close()
            #expect(await ejector.retry(target.id))
            #expect(!image.isAttached)
        }

        @Test func retriesWhenTheLastBlockerExits() async throws {
            let image = try TestDiskImage()
            try image.attach()
            let child = try sleeper(in: image.mountPath)
            defer { child.terminate() }
            let target = try ejectTarget(for: image)

            let ejector = Ejector()
            #expect(await ejector.eject(target) == false)
            let blockers = ejector.statuses[target.id]?.report?.blockers ?? []
            #expect(blockers.map(\.pid) == [child.processIdentifier])

            #expect(ejector.terminate(try #require(blockers.first)))
            let ejected = await wait(upTo: .seconds(10)) { ejector.statuses[target.id] == nil && !image.isAttached }
            #expect(ejected != nil)
        }

        @Test func forceEjectsWithFilesOpen() async throws {
            let image = try TestDiskImage()
            try image.attach()
            let path = image.mountPath + "/open.txt"
            FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
            let handle = try #require(FileHandle(forReadingAtPath: path))
            defer { try? handle.close() }
            let target = try ejectTarget(for: image)

            let ejector = Ejector()
            #expect(await ejector.eject(target) == false)
            #expect(await ejector.retry(target.id, force: true))
            #expect(!image.isAttached)
        }

        @Test func ejectAllCarriesOnPastAFailure() async throws {
            let busy = try TestDiskImage()
            let free = try TestDiskImage()
            try busy.attach()
            try free.attach()
            let path = busy.mountPath + "/open.txt"
            FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
            let handle = try #require(FileHandle(forReadingAtPath: path))
            defer { try? handle.close() }
            let busyTarget = try ejectTarget(for: busy)
            let freeTarget = try ejectTarget(for: free)

            let ejector = Ejector()
            let result = await ejector.ejectAll([busyTarget, freeTarget])
            #expect(result.failed == [busyTarget.id])
            #expect(result.ejected == [freeTarget.name])
            #expect(busy.isAttached)
            #expect(!free.isAttached)
        }

        @Test func ejectsBothMembersOfAnAppleRAIDSet() async throws {
            let directory = FileManager.default.temporaryDirectory.appending(path: "FreesideRAID\(Int.random(in: 10000...99999))")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            var members: [String] = []
            defer { for disk in members { try? TestDiskImage.run("/usr/bin/hdiutil", "detach", "-force", "-quiet", disk) } }
            for index in 0..<2 {
                let file = directory.appending(path: "member\(index).dmg")
                try TestDiskImage.run("/usr/bin/hdiutil", "create", "-size", "200m", "-layout", "NONE", "-quiet", file.path)
                let output = try TestDiskImage.output("/usr/bin/hdiutil", "attach", "-nomount", "-nobrowse", file.path)
                let device = try #require(String(decoding: output, as: UTF8.self).split(separator: " ").first)
                members.append(String(device).replacing("/dev/", with: ""))
            }
            let name = "FreesideRAID\(Int.random(in: 10000...99999))"
            try TestDiskImage.run("/usr/sbin/diskutil", "appleRAID", "create", "stripe", name, "JHFS+", members[0], members[1])
            let bsdName = try mount(at: "/Volumes/\(name)").source.replacing("/dev/", with: "")
            let devices = DeviceMap.devices(forBSDName: bsdName)
            let target = EjectTarget(drive: Drive(id: "raid", name: name, kind: .diskImage, members: devices, volumeIDs: []))

            let ejector = Ejector()
            #expect(await ejector.eject(target))
            #expect(!VolumeStore.mountedFileSystems(includeHidden: true).contains { $0.path == "/Volumes/\(name)" })
            for disk in members { #expect(!FileManager.default.fileExists(atPath: "/dev/\(disk)")) }
        }

        @Test func whoIsUsingThisDoesNotEject() async throws {
            let image = try TestDiskImage()
            try image.attach()
            let child = try sleeper(in: image.mountPath)
            defer { child.terminate() }
            let target = try ejectTarget(for: image)

            let ejector = Ejector()
            await ejector.inspect(target)
            let status = try #require(ejector.statuses[target.id])
            #expect(status.failure == nil)
            #expect(status.report?.blockers.map(\.pid) == [child.processIdentifier])
            #expect(image.isAttached)
        }
    }
}
