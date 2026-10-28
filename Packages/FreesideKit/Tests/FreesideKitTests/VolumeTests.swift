import Foundation
import Testing
@testable import FreesideKit

@Suite struct VolumeKindTests {
    func facts(local: Bool = true, root: Bool = false, model: String? = "SSD", onInternalDevice: Bool?, removable: Bool?) -> VolumeFacts {
        VolumeFacts(isLocal: local, isRoot: root, deviceModel: model, deviceInternal: onInternalDevice, mediaRemovable: removable)
    }

    @Test func fixedUSBDriveIsExternal() {
        // What DiskArbitration reports for a USB SSD: neither removable nor
        // ejectable, but not internal either.
        #expect(VolumeKind(facts(onInternalDevice: false, removable: false)) == .external)
    }

    @Test func cardInBuiltInSlotIsExternal() {
        #expect(VolumeKind(facts(onInternalDevice: true, removable: true)) == .external)
    }

    @Test func diskImageWinsOverRemovable() {
        #expect(VolumeKind(facts(model: "Disk Image", onInternalDevice: nil, removable: true)) == .diskImage)
    }

    @Test func networkWinsOverEverything() {
        #expect(VolumeKind(facts(local: false, model: nil, onInternalDevice: nil, removable: nil)) == .network)
    }

    @Test func bootVolumeIsInternal() {
        #expect(VolumeKind(facts(root: true, onInternalDevice: true, removable: false)) == .internal)
    }

    @Test func internalFixedDiskIsInternal() {
        #expect(VolumeKind(facts(onInternalDevice: true, removable: false)) == .internal)
        #expect(VolumeKind(facts(onInternalDevice: nil, removable: nil)) == .internal)
    }

    @Test func popoverOrder() {
        #expect([VolumeKind.internal, .network, .external, .diskImage].sorted() == [.external, .diskImage, .network, .internal])
    }
}

@Suite struct SpaceTests {
    @Test func availablePrefersFindersNumber() {
        #expect(SpaceReader.available(important: 120, strict: 100) == 120)
    }

    @Test func zeroImportantFallsBackToStrict() {
        // SMB shares report 0 for important-usage capacity.
        #expect(SpaceReader.available(important: 0, strict: 100) == 100)
        #expect(SpaceReader.available(important: nil, strict: 100) == 100)
        #expect(SpaceReader.available(important: nil, strict: nil) == nil)
    }

    @Test func usedFraction() {
        let space = Space(total: 1000, available: 250, availableStrict: 200)
        #expect(space.used == 750)
        #expect(space.usedFraction == 0.75)
        #expect(Space(total: 0, available: 0, availableStrict: 0).usedFraction == 0)
    }

    @Test func formatNames() {
        #expect(FormatName.from(fileSystemType: "apfs") == "APFS")
        #expect(FormatName.from(fileSystemType: "hfs") == "HFS+")
        #expect(FormatName.from(fileSystemType: "smbfs") == "SMB")
        #expect(FormatName.from(fileSystemType: "zfs") == "ZFS")
    }

    @Test func readsTheBootVolume() throws {
        let space = try #require(SpaceReader.readNow(path: "/"))
        #expect(space.total > 0)
        #expect(space.available > 0 && space.available <= space.total)
        #expect(space.availableStrict <= space.available)
    }
}

@Suite struct SpaceReaderTimeoutTests {
    @Test func hungReadTimesOut() async {
        let reader = SpaceReader(timeout: .milliseconds(100)) { _ in
            Thread.sleep(forTimeInterval: 1)
            return Space(total: 1, available: 1, availableStrict: 1)
        }
        let clock = ContinuousClock()
        let start = clock.now
        let space = await reader.read(path: "/hung-\(UUID())")
        #expect(space == nil)
        #expect(clock.now - start < .milliseconds(500))
    }

    @Test func stuckPathIsNotReadAgain() async {
        let path = "/stuck-\(UUID())"
        let reader = SpaceReader(timeout: .milliseconds(50)) { _ in
            Thread.sleep(forTimeInterval: 1)
            return nil
        }
        _ = await reader.read(path: path)
        // The first read is still blocked, so this returns at once.
        let clock = ContinuousClock()
        let start = clock.now
        #expect(await reader.read(path: path) == nil)
        #expect(clock.now - start < .milliseconds(40))
    }

    @Test func fastReadReturnsItsValue() async {
        let expected = Space(total: 10, available: 5, availableStrict: 4)
        let reader = SpaceReader(timeout: .seconds(1)) { _ in expected }
        #expect(await reader.read(path: "/fast-\(UUID())") == expected)
    }
}

@Suite struct MountTableTests {
    @Test func matchesFoundationsVisibleVolumes() {
        let ours = Set(VolumeStore.mountedFileSystems().map(\.path))
        let foundation = Set((FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [], options: [.skipHiddenVolumes]) ?? []).map(\.path))
        #expect(ours == foundation)
    }
}
