import Foundation
import Testing
@testable import FreesideKit

@Suite struct CompactFormatTests {
    @Test(arguments: [
        (0.0, "0"),
        (512, "512B"),
        (999, "999B"),
        (1000, "1.0K"),
        (12_400_000, "12M"),
        (412_000_000, "412M"),
        (999_600_000, "1.0G"),
        (9_960_000_000, "10G"),
        (1_234_000_000_000, "1.2T"),
        (856_000_000_000, "856G"),
    ])
    func decimal(bytes: Double, expected: String) {
        #expect(Format.compact(bytes) == expected)
        #expect(Format.compact(bytes).count <= 4)
    }

    @Test func binary() {
        #expect(Format.compact(1_073_741_824, units: .binary) == "1.0G")
        #expect(Format.compact(1_000_000_000, units: .binary) == "954M")
    }

    @Test func sizesAndRatesFollowTheUnits() {
        #expect(Format.size(2_600_000_000_000, units: .decimal) == "2.6 TB")
        #expect(Format.size(2_600_000_000_000, units: .binary) == "2.4 TiB")
        #expect(Format.size(-5, units: .decimal) == "0 B")
        #expect(Format.rate(412_000_000, units: .decimal) == "412 MB/s")
        #expect(Format.rate(412_000_000, units: .binary) == "393 MiB/s")
    }

    @Test func spoken() {
        #expect(Format.spoken(bytes: 1_200_000_000_000) == "1.2 terabytes")
        #expect(Format.spoken(bytes: 380_000_000, perSecond: true) == "380 megabytes per second")
    }
}

@Suite struct LowSpaceTests {
    let space = Space(total: 1_000_000_000_000, available: 80_000_000_000, availableStrict: 70_000_000_000)

    @Test func percent() {
        #expect(LowSpaceThreshold.percent(10).isLow(space))
        #expect(!LowSpaceThreshold.percent(5).isLow(space))
    }

    @Test func gigabytes() {
        #expect(LowSpaceThreshold.gigabytes(100).isLow(space))
        #expect(!LowSpaceThreshold.gigabytes(50).isLow(space))
    }

    @Test func rawValues() {
        #expect(LowSpaceThreshold(rawValue: "percent:10") == .percent(10))
        #expect(LowSpaceThreshold(rawValue: "gigabytes:50") == .gigabytes(50))
        #expect(LowSpaceThreshold(rawValue: "percent:0") == nil)
        #expect(LowSpaceThreshold(rawValue: "junk") == nil)
    }

    @Test func emptyVolumeIsNotLow() {
        #expect(!LowSpaceThreshold.percent(10).isLow(Space(total: 0, available: 0, availableStrict: 0)))
    }
}

@Suite struct TransferDetectorTests {
    let start = ContinuousClock.now

    func at(_ seconds: Double) -> ContinuousClock.Instant { start + .milliseconds(Int(seconds * 1000)) }

    @Test func startsAfterThreeSecondsOverOneMegabyte() {
        var detector = TransferDetector()
        detector.update(rate: 5_000_000, at: at(0))
        #expect(detector.isPending)
        detector.update(rate: 5_000_000, at: at(2))
        #expect(!detector.isActive)
        detector.update(rate: 5_000_000, at: at(3))
        #expect(detector.isActive)
        #expect(!detector.isPending)
    }

    @Test func aDipResetsTheStart() {
        var detector = TransferDetector()
        detector.update(rate: 5_000_000, at: at(0))
        detector.update(rate: 100, at: at(1))
        #expect(!detector.isPending)
        detector.update(rate: 5_000_000, at: at(2))
        detector.update(rate: 5_000_000, at: at(4))
        #expect(!detector.isActive)
        detector.update(rate: 5_000_000, at: at(5))
        #expect(detector.isActive)
    }

    @Test func endsTenSecondsAfterDroppingBelow() {
        var detector = TransferDetector()
        detector.update(rate: 5_000_000, at: at(0))
        detector.update(rate: 5_000_000, at: at(3))
        detector.update(rate: 0, at: at(4))
        detector.update(rate: 0, at: at(13))
        #expect(detector.isActive)
        // A burst in the tail keeps it going and restarts the countdown.
        detector.update(rate: 5_000_000, at: at(13.5))
        detector.update(rate: 0, at: at(14))
        detector.update(rate: 0, at: at(23))
        #expect(detector.isActive)
        detector.update(rate: 0, at: at(24))
        #expect(!detector.isActive)
    }

    @Test func fiveSecondChecksStartAfterTwoSamples() {
        // Idle checks run every 5 s; the second sample over the threshold starts it.
        var detector = TransferDetector()
        let first = detector.update(rate: 5_000_000, at: at(0))
        let second = detector.update(rate: 5_000_000, at: at(5))
        #expect(first && second)
        #expect(detector.isActive)
    }
}

@Suite struct MenuBarStyleTests {
    @Test func switchesToActivityDuringTransfers() {
        #expect(MenuBarStyle.icon.effective(pinnedMounted: true, transferring: true, activityDuringTransfers: true) == .activity)
        #expect(MenuBarStyle.space.effective(pinnedMounted: true, transferring: true, activityDuringTransfers: true) == .activity)
        #expect(MenuBarStyle.icon.effective(pinnedMounted: true, transferring: true, activityDuringTransfers: false) == .icon)
        #expect(MenuBarStyle.spaceActivity.effective(pinnedMounted: true, transferring: true, activityDuringTransfers: true) == .spaceActivity)
    }

    @Test func fallsBackWithoutThePinnedVolume() {
        #expect(MenuBarStyle.space.effective(pinnedMounted: false, transferring: false, activityDuringTransfers: true) == .icon)
        #expect(MenuBarStyle.spaceActivity.effective(pinnedMounted: false, transferring: false, activityDuringTransfers: true) == .activity)
    }

    @Test func onlyActivityStylesDrawTheTrace() {
        #expect(MenuBarStyle.activity.showsTrace(traceOn: true))
        #expect(MenuBarStyle.spaceActivity.showsTrace(traceOn: true))
        #expect(!MenuBarStyle.activity.showsTrace(traceOn: false))
        // Icon and space switch to rates alone during a transfer.
        #expect(!MenuBarStyle.icon.showsTrace(traceOn: true))
        #expect(!MenuBarStyle.space.showsTrace(traceOn: true))
    }

    @Test func reservesWidthForEveryStyleItCanShow() {
        #expect(MenuBarStyle.icon.reserved(activityDuringTransfers: true) == [.icon, .activity])
        #expect(MenuBarStyle.icon.reserved(activityDuringTransfers: false) == [.icon])
        #expect(MenuBarStyle.space.reserved(activityDuringTransfers: true) == [.space, .icon, .activity])
        #expect(MenuBarStyle.spaceActivity.reserved(activityDuringTransfers: true) == [.spaceActivity, .activity])
        // Every effective style is reserved.
        for style in MenuBarStyle.allCases {
            for pinned in [true, false] {
                for transferring in [true, false] {
                    for during in [true, false] {
                        let shown = style.effective(pinnedMounted: pinned, transferring: transferring, activityDuringTransfers: during)
                        #expect(style.reserved(activityDuringTransfers: during).contains(shown))
                    }
                }
            }
        }
    }

    @Test func defaultPinnedVolume() {
        func volume(_ name: String, _ kind: VolumeKind, boot: Bool = false) -> Volume {
            Volume(id: name, name: name, mountPath: "/Volumes/\(name)", bsdName: nil, kind: kind, format: "APFS", isBoot: boot)
        }
        let boot = volume("Macintosh HD", .internal, boot: true)
        #expect(Volume.defaultPinned(in: [boot, volume("RAID", .external)])?.name == "RAID")
        #expect(Volume.defaultPinned(in: [volume("Share", .network), boot])?.name == "Macintosh HD")
    }
}
