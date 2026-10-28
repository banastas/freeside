import Foundation
import Testing
@testable import FreesideKit

@Suite struct FormatTests {
    @Test(arguments: [
        (0.0, "0 B/s"),
        (999, "999 B/s"),
        (1000, "1.0 KB/s"),
        (1234, "1.2 KB/s"),
        (999_600, "1.0 MB/s"),
        (412_000_000, "412 MB/s"),
        (2_800_000_000, "2.8 GB/s"),
    ])
    func rate(bytes: Double, expected: String) {
        #expect(Format.rate(bytes) == expected)
    }

    @Test func decimalBytes() {
        #expect(Format.decimalBytes(1_200_000_000_000) == "1.2 TB")
        #expect(Format.decimalBytes(512_000_000) == "512 MB")
    }
}

@Suite struct RingBufferTests {
    @Test func startsFullOfFill() {
        let buffer = RingBuffer(capacity: 3, fill: 0)
        #expect(buffer.elements == [0, 0, 0])
    }

    @Test func keepsNewestOldestFirst() {
        var buffer = RingBuffer(capacity: 3, fill: 0)
        for value in 1...5 { buffer.append(value) }
        #expect(buffer.elements == [3, 4, 5])
        #expect(buffer.suffix(2) == [4, 5])
        #expect(buffer.last == 5)
    }
}
