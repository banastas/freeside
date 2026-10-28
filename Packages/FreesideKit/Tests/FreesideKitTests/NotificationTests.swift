import Foundation
import Testing
@testable import FreesideKit

@Suite struct LowSpaceWatchTests {
    func volume(available: Int64, id: String = "v", stale: Bool = false) -> Volume {
        Volume(
            id: id, name: id, mountPath: "/Volumes/\(id)", bsdName: nil, kind: .external, format: "APFS", isBoot: false,
            space: Space(total: 1_000_000_000_000, available: available, availableStrict: available, isStale: stale)
        )
    }

    @Test func notifiesOncePerCrossing() {
        var watch = LowSpaceWatch()
        let threshold = LowSpaceThreshold.percent(10)
        #expect(watch.update([volume(available: 200_000_000_000)], threshold: threshold).isEmpty)
        #expect(watch.update([volume(available: 90_000_000_000)], threshold: threshold).map(\.id) == ["v"])
        // Still low, or back just above the threshold: no repeat.
        #expect(watch.update([volume(available: 80_000_000_000)], threshold: threshold).isEmpty)
        #expect(watch.update([volume(available: 105_000_000_000)], threshold: threshold).isEmpty)
        #expect(watch.update([volume(available: 95_000_000_000)], threshold: threshold).isEmpty)
        // Clear by the 10 % margin re-arms it.
        #expect(watch.update([volume(available: 111_000_000_000)], threshold: threshold).isEmpty)
        #expect(watch.update([volume(available: 95_000_000_000)], threshold: threshold).map(\.id) == ["v"])
    }

    @Test func alreadyLowWhenFirstSeenIsNotACrossing() {
        var watch = LowSpaceWatch()
        #expect(watch.update([volume(available: 10_000_000_000)], threshold: .percent(10)).isEmpty)
        #expect(watch.update([volume(available: 9_000_000_000)], threshold: .percent(10)).isEmpty)
    }

    @Test func changingTheThresholdStartsOver() {
        var watch = LowSpaceWatch()
        _ = watch.update([volume(available: 150_000_000_000)], threshold: .percent(10))
        #expect(watch.update([volume(available: 150_000_000_000)], threshold: .percent(20)).isEmpty)
    }

    @Test func staleValuesAreIgnored() {
        var watch = LowSpaceWatch()
        _ = watch.update([volume(available: 200_000_000_000)], threshold: .percent(10))
        #expect(watch.update([volume(available: 10_000_000_000, stale: true)], threshold: .percent(10)).isEmpty)
        #expect(watch.update([volume(available: 10_000_000_000)], threshold: .percent(10)).map(\.id) == ["v"])
    }

    @Test func gigabyteThreshold() {
        let threshold = LowSpaceThreshold.gigabytes(50)
        let space = Space(total: 1_000_000_000_000, available: 54_000_000_000, availableStrict: 54_000_000_000)
        #expect(!threshold.isLow(space))
        #expect(!threshold.isClear(space))
        #expect(threshold.isClear(Space(total: 1_000_000_000_000, available: 56_000_000_000, availableStrict: 0)))
    }
}

@Suite struct WriteSessionTests {
    let start = ContinuousClock.now
    func at(_ seconds: Double) -> ContinuousClock.Instant { start + .milliseconds(Int(seconds * 1000)) }

    @Test func reportsAFinishedTransferOfAtLeastOneGigabyte() {
        var session = WriteSession()
        #expect(session.update(writeRate: 0, written: 0, at: at(0)) == nil)
        #expect(!session.isOpen)
        // 400 MB/s for 5 s, sampled every 5 s.
        #expect(session.update(writeRate: 400_000_000, written: 2_000_000_000, at: at(5)) == nil)
        #expect(session.isOpen)
        #expect(session.update(writeRate: 0, written: 1_000_000, at: at(10)) == nil)
        #expect(session.update(writeRate: 0, written: 0, at: at(15)) == nil)
        #expect(session.update(writeRate: 0, written: 0, at: at(20)) == FinishedTransfer(bytes: 2_001_000_000, duration: .seconds(5)))
        #expect(!session.isOpen)
    }

    @Test func aPauseShorterThanTenSecondsKeepsItGoing() {
        var session = WriteSession()
        _ = session.update(writeRate: 100_000_000, written: 500_000_000, at: at(0))
        _ = session.update(writeRate: 0, written: 0, at: at(5))
        _ = session.update(writeRate: 100_000_000, written: 500_000_000, at: at(10))
        #expect(session.bytes == 1_000_000_000)
        #expect(session.update(writeRate: 0, written: 0, at: at(15)) == nil)
        #expect(session.update(writeRate: 0, written: 0, at: at(25)) != nil)
    }

    @Test func smallTransfersAreNotReported() {
        var session = WriteSession()
        _ = session.update(writeRate: 50_000_000, written: 250_000_000, at: at(0))
        _ = session.update(writeRate: 0, written: 0, at: at(1))
        #expect(session.update(writeRate: 0, written: 0, at: at(11)) == nil)
        #expect(!session.isOpen)
    }
}

@Suite struct DiagnosticsTests {
    @Test func reportHasTheMapAndNoScanPaths() {
        let volume = Volume(
            id: "u", name: "Photography", mountPath: "/Volumes/Photography", bsdName: "disk7s1", kind: .external,
            format: "APFS", deviceProtocol: "USB", isBoot: false,
            space: Space(total: 4_000_000_000_000, available: 2_500_000_000_000, availableStrict: 2_400_000_000_000)
        )
        let drive = Drive(
            id: "1", name: "G-DRIVE", deviceProtocol: "USB", kind: .external,
            members: [BlockDevice(driverID: 1, bsdName: "disk6")], volumeIDs: ["u"], readRate: 0, writeRate: 0
        )
        let report = Diagnostics.report(
            environment: .init(appVersion: "0.1.0", build: "1", osVersion: "27.2", model: "Mac14,12", settings: ["style icon"]),
            volumes: [volume],
            drives: [drive],
            log: [.init(date: .now, targetName: "G-DRIVE", kind: .external, failure: .other(status: Int32(bitPattern: 0xF8DA_0010), message: nil))],
            lastScan: .init(duration: .milliseconds(32), processCount: 546, blockerCount: 1, imageCount: 0, scannedMappedFiles: false)
        )
        #expect(report.contains("G-DRIVE · external · USB · disk6 · I/O statistics"))
        #expect(report.contains("Photography · external · APFS · USB · disk7s1"))
        #expect(report.contains("0xF8DA0010"))
        #expect(report.contains("32 ms · 546 processes · 1 holding"))
        #expect(report.contains("Mac14,12"))
        // Mount paths are only in the scan's paths, which the report never gets.
        #expect(!report.contains("/Volumes/"))
    }
}
