import Foundation

/// Per-phase CPU cost of each tick, for checking the PRD §8 budgets. From flatline.
/// Run the app binary with `FREESIDE_PROFILE=1`; every 60 ticks it prints the
/// average thread CPU time per phase to stderr. Thread CPU time ignores time
/// spent preempted, so results hold up on a busy machine. The first
/// `warmUpTicks` are discarded: they include one-time work such as
/// rasterizing each character, which a long-running app pays once.
@MainActor
public enum Profiler {
    public static let enabled = ProcessInfo.processInfo.environment["FREESIDE_PROFILE"] != nil
    private static var totals: [String: UInt64] = [:]
    private static var counts: [String: Int] = [:]
    private static var order: [String] = []
    private static var ticks = 0
    private static let warmUpTicks = 10
    private static var warmedUp = false

    public static func measure<T>(_ name: String, _ body: () -> T) -> T {
        guard enabled else { return body() }
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let result = body()
        let elapsed = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start
        if totals[name] == nil { order.append(name) }
        totals[name, default: 0] += elapsed
        counts[name, default: 0] += 1
        return result
    }

    public static func endTick() {
        guard enabled else { return }
        ticks += 1
        if !warmedUp, ticks == warmUpTicks {
            warmedUp = true
            totals.removeAll()
            counts.removeAll()
            order.removeAll()
            ticks = 0
            return
        }
        guard ticks % 60 == 0 else { return }
        // name=average µs per tick, ×calls per tick when a phase runs more or less than once.
        let line = order.map { name in
            let perTick = Double(counts[name, default: 0]) / Double(ticks)
            let calls = abs(perTick - 1) < 0.05 ? "" : String(format: "×%.1f", perTick)
            return "\(name)=\(totals[name, default: 0] / UInt64(ticks) / 1000)µs\(calls)"
        }.joined(separator: " ")
        FileHandle.standardError.write(Data("[\(ticks)] avg/tick \(line)\n".utf8))
    }
}
