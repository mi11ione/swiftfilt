// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// Measurement substrate: monotonic timing, warmup + N-run medians with
// spread, a dead-code-elimination sink, deterministic SplitMix64,
// machine-info capture, and the JSON document the nightly regression
// guard consumes. Methodology (documented once, applied to every
// benchmark): unrecorded warmup runs (1 unless a benchmark documents
// more), then `runs` recorded runs; the reported figure is the MEDIAN;
// spread = (max − min) / median over the recorded runs. Timing uses
// `ContinuousClock` (monotonic — wall time).
//
// Beyond wall time, every benchmark records three more dimensions:
//   CPU time    user+system rusage delta per recorded run. On a fixed
//               host, CPU-time × core frequency is the honest power
//               proxy for this battery (single-threaded, cache-resident
//               compute: energy tracks active core-cycles, which wall
//               time misstates whenever the process is descheduled).
//   peak RSS Δ  growth of the process's high-water resident-set mark
//               (`ru_maxrss`) across the workload. The mark is
//               monotonic for the process, so a workload whose
//               footprint fits inside an earlier workload's peak reads
//               0 — a per-workload ceiling contribution, not its
//               working-set size.
//   allocations events + requested bytes from one extra unrecorded
//               pass with libmalloc's `malloc_logger` hook installed
//               (the exported global MallocStackLogging attaches to;
//               no env var, no stack capture — just counters). Counts
//               are process-wide malloc/calloc/realloc events during
//               the pass; the hooked pass is never timed.

import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

// MARK: - Dead-code-elimination sink

/// Opaque sink the optimizer cannot see through; every timed loop folds
/// its observable results into a checksum and hands it here so the work
/// cannot be elided.
@inline(never)
func blackhole(_ value: UInt64) {
    Sink.value ^= value
}

enum Sink {
    nonisolated(unsafe) static var value: UInt64 = 0
}

/// Cheap deterministic fold of a string into the sink domain: length
/// plus first/last byte — enough to force the value to exist.
@inline(__always)
func foldString(_ s: String) -> UInt64 {
    let utf8 = s.utf8
    return UInt64(utf8.count) &* 31 &+ UInt64(utf8.first ?? 0) &+ (UInt64(utf8.last ?? 0) << 8)
}

// MARK: - Deterministic PRNG

/// SplitMix64 — the project's deterministic sweep generator (the same
/// algorithm the parity tool uses), so inputs are reproducible from the
/// seed alone.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - CPU time + peak RSS

/// Whose CPU time a benchmark's rusage bracket reads: the harness
/// process itself, or its reaped children (the CLI-wall rows — the
/// child does the work, and the children scope accumulates exactly at
/// reap, so a per-run delta is that run's child).
enum CPUScope {
    case selfProcess
    case children
}

/// The consumed CPU time (user + system) in seconds for `scope`.
func processCPUSeconds(scope: CPUScope = .selfProcess) -> Double {
    var usage = rusage()
    let who = scope == .selfProcess ? RUSAGE_SELF : RUSAGE_CHILDREN
    guard getrusage(who, &usage) == 0 else { return 0 }
    let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) * 1e-6
    let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) * 1e-6
    return user + system
}

/// The process's peak resident-set high-water mark, in bytes
/// (`ru_maxrss` is bytes on Darwin, KiB on Linux). Monotonic.
func peakRSSBytes() -> UInt64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    #if canImport(Darwin)
        return UInt64(max(0, usage.ru_maxrss))
    #else
        return UInt64(max(0, usage.ru_maxrss)) * 1024
    #endif
}

// MARK: - Allocation counting (malloc_logger)

#if canImport(Darwin)
    /// libmalloc's logging hook signature: `malloc_logger_t` in
    /// libmalloc's `stack_logging.h` — `(type, arg1, arg2, arg3, result,
    /// num_hot_frames_to_skip)`. For allocation events the requested size
    /// is `arg2` (malloc/calloc/valloc: type = alloc|zone) or `arg3`
    /// (realloc: type = alloc|dealloc|zone, arg2 = old pointer).
    private typealias MallocLoggerFn = @convention(c) (
        UInt32, UInt, UInt, UInt, UInt, UInt32
    ) -> Void

    /// The exported `malloc_logger` global — libmalloc calls whatever
    /// function pointer sits here on every zone allocation event. `nil`
    /// when the symbol is unavailable. (`nonisolated(unsafe)`: resolved
    /// once, then only read; the pointee is toggled by begin()/end()
    /// from the single benchmark thread.)
    private nonisolated(unsafe) let mallocLoggerSlot: UnsafeMutablePointer<MallocLoggerFn?>? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "malloc_logger") else { return nil }
        return symbol.assumingMemoryBound(to: MallocLoggerFn?.self)
    }()

    /// `stack_logging_type_alloc` — set on malloc/calloc/valloc/realloc.
    private let stackLoggingTypeAlloc: UInt32 = 2
    /// `stack_logging_type_dealloc` — set on free, and on realloc
    /// (which both frees and allocates in one event).
    private let stackLoggingTypeDealloc: UInt32 = 4

    /// The counting hook. MUST NOT allocate (libmalloc calls it inside
    /// every allocation): plain counter increments under an unfair lock
    /// (whose storage is pre-allocated before the hook is installed).
    private let countingMallocLogger: MallocLoggerFn = { type, _, arg2, arg3, _, _ in
        guard type & stackLoggingTypeAlloc != 0 else { return }
        let size = type & stackLoggingTypeDealloc != 0 ? arg3 : arg2
        AllocationCounter.record(size: UInt64(size))
    }
#endif

/// Process-wide allocation-event counters for one measurement pass.
/// Darwin-only (the hook is libmalloc's); ``begin()`` reports whether
/// counting is available so callers can omit the stats honestly.
enum AllocationCounter {
    #if canImport(Darwin)
        /// Lock storage at a stable address, allocated (and the counters
        /// touched) BEFORE the hook installs — the hook itself must never
        /// trigger an allocation.
        private nonisolated(unsafe) static let lock: UnsafeMutablePointer<os_unfair_lock_s> = {
            let pointer = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
            pointer.initialize(to: os_unfair_lock_s())
            return pointer
        }()

        private nonisolated(unsafe) static var events: UInt64 = 0
        private nonisolated(unsafe) static var bytes: UInt64 = 0
        private nonisolated(unsafe) static var savedLogger: MallocLoggerFn?

        fileprivate static func record(size: UInt64) {
            os_unfair_lock_lock(lock)
            events &+= 1
            bytes &+= size
            os_unfair_lock_unlock(lock)
        }
    #endif

    /// Zero the counters and install the hook. Returns `false` (and
    /// installs nothing) where counting is unavailable.
    static func begin() -> Bool {
        #if canImport(Darwin)
            guard let slot = mallocLoggerSlot else { return false }
            os_unfair_lock_lock(lock)
            events = 0
            bytes = 0
            os_unfair_lock_unlock(lock)
            savedLogger = slot.pointee
            slot.pointee = countingMallocLogger
            return true
        #else
            return false
        #endif
    }

    /// Uninstall the hook (restoring whatever was there) and read the
    /// counters: (allocation events, requested bytes).
    static func end() -> (events: UInt64, bytes: UInt64) {
        #if canImport(Darwin)
            guard let slot = mallocLoggerSlot else { return (0, 0) }
            slot.pointee = savedLogger
            savedLogger = nil
            os_unfair_lock_lock(lock)
            let result = (events, bytes)
            os_unfair_lock_unlock(lock)
            return result
        #else
            return (0, 0)
        #endif
    }
}

// MARK: - Timing

/// One benchmark's recorded runs and derived statistics.
struct BenchResult {
    /// Stable metric identifier (the baseline file keys on it).
    let name: String
    /// Unit of `median` (e.g. "symbols/s", "ns/op").
    let unit: String
    /// Whether larger values are better (throughput) or worse (latency) —
    /// drives the one-sided regression comparison.
    let largerIsBetter: Bool
    /// Every recorded run, in execution order.
    let runs: [Double]
    /// Optional free-form note (sample sizes, caveats).
    let note: String?
    /// Operations per recorded run (the denominator for per-op CPU and
    /// allocation figures), with the operation's display label.
    let opsPerRun: Double?
    /// What one "op" is for the per-op resource figures ("op", "symbol", "MB").
    let opLabel: String
    /// CPU seconds (user+system) per recorded run, aligned with `runs`.
    let cpuSeconds: [Double]
    /// Wall seconds per recorded run (sampled around the same body the
    /// CPU delta brackets), aligned with `runs`.
    let wallSeconds: [Double]
    /// Growth of the process peak-RSS high-water mark across this
    /// workload's warmup + recorded runs (monotonic mark — see header).
    let peakRSSDeltaBytes: UInt64
    /// Allocation events in one unrecorded hooked pass, `nil` when the
    /// malloc_logger hook is unavailable.
    let allocEvents: UInt64?
    /// Requested bytes across those events.
    let allocBytes: UInt64?
    /// For subprocess workloads: the CHILD's peak resident set from one
    /// unrecorded `/usr/bin/time -l` pass (the parent's own RSS says
    /// nothing about the contender). `nil` for in-process workloads.
    var childPeakRSSBytes: UInt64?

    var median: Double {
        Self.median(of: runs)
    }

    static func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[mid] }
        return (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Median CPU seconds over the recorded runs.
    var cpuMedianSeconds: Double {
        Self.median(of: cpuSeconds)
    }

    /// Median of per-run CPU/wall ratios — 1.0 means the workload had a
    /// core for its entire wall time; lower means descheduling.
    var cpuUtilizationMedian: Double {
        let ratios = zip(cpuSeconds, wallSeconds).compactMap { cpu, wall in
            wall > 0 ? cpu / wall : nil
        }
        return Self.median(of: ratios)
    }

    /// Median CPU nanoseconds per operation, when `opsPerRun` is known.
    var cpuPerOpNanoseconds: Double? {
        guard let opsPerRun, opsPerRun > 0 else { return nil }
        return cpuMedianSeconds / opsPerRun * 1e9
    }

    /// Allocation events per operation from the hooked pass.
    var allocEventsPerOp: Double? {
        guard let allocEvents, let opsPerRun, opsPerRun > 0 else { return nil }
        return Double(allocEvents) / opsPerRun
    }

    /// Requested bytes per operation from the hooked pass.
    var allocBytesPerOp: Double? {
        guard let allocBytes, let opsPerRun, opsPerRun > 0 else { return nil }
        return Double(allocBytes) / opsPerRun
    }

    var min: Double {
        runs.min() ?? 0
    }

    var max: Double {
        runs.max() ?? 0
    }

    /// Relative spread: (max − min) / median; 0 when degenerate.
    var spread: Double {
        let m = median
        guard m != 0 else { return 0 }
        return (max - min) / m
    }
}

/// Run `body` `warmups` times unrecorded (default 1), then `runs`
/// recorded times. `body` returns the run's metric value (already in
/// the result unit — the caller converts duration to symbols/s or
/// ns/op). Benchmarks whose first passes are dominated by one-time
/// costs (cold page-in of a large buffer) pass a larger `warmups` and
/// say so in their note.
///
/// Each recorded run also samples the rusage CPU delta and a wall clock
/// around the body (the bodies do all their work inside their timed
/// region, so the brackets and the metric describe the same work).
/// After the recorded runs, one extra unrecorded pass executes with the
/// allocation hook installed — hook overhead never touches the timings.
/// `opsPerRun`/`opLabel` name the denominator for the per-op resource
/// figures.
func measure(
    name: String,
    unit: String,
    largerIsBetter: Bool,
    runs: Int,
    warmups: Int = 1,
    opsPerRun: Double? = nil,
    opLabel: String = "op",
    cpuScope: CPUScope = .selfProcess,
    countAllocations: Bool = true,
    note: String? = nil,
    body: () -> Double,
) -> BenchResult {
    let peakRSSBefore = peakRSSBytes()
    for _ in 0 ..< warmups {
        _ = body()
    }
    var recorded: [Double] = []
    var cpu: [Double] = []
    var wall: [Double] = []
    recorded.reserveCapacity(runs)
    cpu.reserveCapacity(runs)
    wall.reserveCapacity(runs)
    let clock = ContinuousClock()
    for _ in 0 ..< runs {
        let cpuBefore = processCPUSeconds(scope: cpuScope)
        let wallStart = clock.now
        recorded.append(body())
        let wallDuration = clock.now - wallStart
        cpu.append(processCPUSeconds(scope: cpuScope) - cpuBefore)
        let comps = wallDuration.components
        wall.append(Double(comps.seconds) + Double(comps.attoseconds) * 1e-18)
    }
    let peakRSSAfter = peakRSSBytes()
    var allocEvents: UInt64?
    var allocBytes: UInt64?
    if countAllocations, AllocationCounter.begin() {
        _ = body()
        let counted = AllocationCounter.end()
        allocEvents = counted.events
        allocBytes = counted.bytes
    }
    return BenchResult(
        name: name, unit: unit, largerIsBetter: largerIsBetter,
        runs: recorded, note: note,
        opsPerRun: opsPerRun, opLabel: opLabel,
        cpuSeconds: cpu, wallSeconds: wall,
        peakRSSDeltaBytes: peakRSSAfter >= peakRSSBefore ? peakRSSAfter - peakRSSBefore : 0,
        allocEvents: allocEvents, allocBytes: allocBytes,
    )
}

/// Time one execution of `body`, returning seconds.
func timed(_ body: () -> Void) -> Double {
    let clock = ContinuousClock()
    let duration = clock.measure(body)
    let comps = duration.components
    return Double(comps.seconds) + Double(comps.attoseconds) * 1e-18
}

// MARK: - Machine info

struct MachineInfo {
    let cpuBrand: String
    let physicalCores: Int
    let logicalCores: Int
    let performanceCores: Int?
    let efficiencyCores: Int?
    let memoryBytes: UInt64
    let osVersion: String
    let swiftVersion: String

    static func capture() -> MachineInfo {
        MachineInfo(
            cpuBrand: sysctlString("machdep.cpu.brand_string") ?? linuxCPUModel() ?? "unknown",
            physicalCores: Int(sysctlUInt64("hw.physicalcpu") ?? UInt64(ProcessInfo.processInfo.processorCount)),
            logicalCores: Int(sysctlUInt64("hw.logicalcpu") ?? UInt64(ProcessInfo.processInfo.activeProcessorCount)),
            performanceCores: sysctlUInt64("hw.perflevel0.physicalcpu").map(Int.init),
            efficiencyCores: sysctlUInt64("hw.perflevel1.physicalcpu").map(Int.init),
            memoryBytes: sysctlUInt64("hw.memsize") ?? ProcessInfo.processInfo.physicalMemory,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            swiftVersion: capturedSwiftVersion(),
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        #if canImport(Darwin)
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
            return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        #else
            return nil
        #endif
    }

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        #if canImport(Darwin)
            var value: UInt64 = 0
            var size = MemoryLayout<UInt64>.size
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return value
        #else
            return nil
        #endif
    }

    private static func linuxCPUModel() -> String? {
        guard let text = try? String(contentsOfFile: "/proc/cpuinfo", encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("model name") {
            if let colon = line.firstIndex(of: ":") {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// `swift --version`'s first line when the toolchain is reachable;
    /// otherwise the compiler-version bucket this binary was built with.
    private static func capturedSwiftVersion() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        if (try? process.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let line = String(data: data, encoding: .utf8)?
                .split(separator: "\n").first(where: { $0.contains("Swift version") })
            {
                return line.trimmingCharacters(in: .whitespaces)
            }
        }
        #if compiler(>=6.3)
            return "compiler >= 6.3 (toolchain query failed)"
        #elseif compiler(>=6.2)
            return "compiler >= 6.2 (toolchain query failed)"
        #else
            return "compiler >= 6.0 (toolchain query failed)"
        #endif
    }
}

// MARK: - Formatting + JSON

func groupedInt(_ value: Double) -> String {
    let v = Int64(value.rounded())
    var digits = Array(String(v.magnitude))
    var out: [Character] = []
    while digits.count > 3 {
        out.insert(contentsOf: ",\(String(digits.suffix(3)))", at: out.startIndex)
        digits.removeLast(3)
    }
    out.insert(contentsOf: String(digits), at: out.startIndex)
    return (v < 0 ? "-" : "") + String(out)
}

func formatValue(_ value: Double, unit _: String) -> String {
    if value < 1000 { return String(format: "%.2f", value) }
    return groupedInt(value)
}

/// Render the full results document as deterministic JSON (stable key
/// order, no Foundation Codable round-trip).
func renderJSON(machine: MachineInfo, config: [(String, String)], results: [BenchResult], coverage: [CoverageResult] = []) -> String {
    func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
    var lines: [String] = []
    lines.append("{")
    lines.append("  \"schema\": \"swiftfilt-bench/3\",")
    lines.append("  \"timestamp\": \"\(ISO8601DateFormatter().string(from: Date()))\",")
    lines.append("  \"machine\": {")
    lines.append("    \"cpu\": \"\(esc(machine.cpuBrand))\",")
    lines.append("    \"physicalCores\": \(machine.physicalCores),")
    lines.append("    \"logicalCores\": \(machine.logicalCores),")
    lines.append("    \"performanceCores\": \(machine.performanceCores.map(String.init) ?? "null"),")
    lines.append("    \"efficiencyCores\": \(machine.efficiencyCores.map(String.init) ?? "null"),")
    lines.append("    \"memoryBytes\": \(machine.memoryBytes),")
    lines.append("    \"os\": \"\(esc(machine.osVersion))\",")
    lines.append("    \"swift\": \"\(esc(machine.swiftVersion))\"")
    lines.append("  },")
    lines.append("  \"config\": {")
    lines.append(config.map { "    \"\($0.0)\": \"\(esc($0.1))\"" }.joined(separator: ",\n"))
    lines.append("  },")
    lines.append("  \"results\": [")
    var blocks: [String] = []
    for r in results {
        var b = "    {\n"
        b += "      \"name\": \"\(r.name)\",\n"
        b += "      \"unit\": \"\(r.unit)\",\n"
        b += "      \"largerIsBetter\": \(r.largerIsBetter),\n"
        b += "      \"runs\": [\(r.runs.map { String($0) }.joined(separator: ", "))],\n"
        b += "      \"median\": \(r.median),\n"
        b += "      \"min\": \(r.min),\n"
        b += "      \"max\": \(r.max),\n"
        b += "      \"spread\": \(r.spread),\n"
        if let opsPerRun = r.opsPerRun {
            b += "      \"opsPerRun\": \(opsPerRun),\n"
            b += "      \"opLabel\": \"\(esc(r.opLabel))\",\n"
        }
        b += "      \"cpuSecondsPerRun\": [\(r.cpuSeconds.map { String($0) }.joined(separator: ", "))],\n"
        b += "      \"cpuMedianSeconds\": \(r.cpuMedianSeconds),\n"
        b += "      \"cpuUtilizationMedian\": \(r.cpuUtilizationMedian),\n"
        if let cpuPerOp = r.cpuPerOpNanoseconds {
            b += "      \"cpuPerOpNanoseconds\": \(cpuPerOp),\n"
        }
        if let events = r.allocEvents, let bytes = r.allocBytes {
            b += "      \"allocEventsPerPass\": \(events),\n"
            b += "      \"allocBytesPerPass\": \(bytes),\n"
            if let perOp = r.allocEventsPerOp {
                b += "      \"allocEventsPerOp\": \(perOp),\n"
            }
            if let perOp = r.allocBytesPerOp {
                b += "      \"allocBytesPerOp\": \(perOp),\n"
            }
        }
        b += "      \"peakRSSDeltaBytes\": \(r.peakRSSDeltaBytes)"
        if let childRSS = r.childPeakRSSBytes {
            b += ",\n      \"childPeakRSSBytes\": \(childRSS)"
        }
        if let note = r.note {
            b += ",\n      \"note\": \"\(esc(note))\""
        }
        b += "\n    }"
        blocks.append(b)
    }
    lines.append(blocks.joined(separator: ",\n"))
    if coverage.isEmpty {
        lines.append("  ]")
    } else {
        lines.append("  ],")
        lines.append(renderCoverageJSON(coverage))
    }
    lines.append("}")
    return lines.joined(separator: "\n")
}

/// Human-readable result line for the console mode.
func printResult(_ r: BenchResult) {
    let runsText = r.runs.map { formatValue($0, unit: r.unit) }.joined(separator: " / ")
    var line = "  \(r.name): median \(formatValue(r.median, unit: r.unit)) \(r.unit)"
    line += "  (runs: \(runsText); spread \(String(format: "%.1f", r.spread * 100))%)"
    print(line)
    var resources = "    cpu: "
    if let cpuPerOp = r.cpuPerOpNanoseconds {
        resources += "\(formatValue(cpuPerOp, unit: "ns")) ns/\(r.opLabel)"
    } else {
        resources += "\(String(format: "%.3f", r.cpuMedianSeconds)) s/run"
    }
    resources += " · utilization \(String(format: "%.1f", r.cpuUtilizationMedian * 100))%"
    if let events = r.allocEventsPerOp, let bytes = r.allocBytesPerOp {
        resources += " · allocs \(String(format: "%.1f", events))/\(r.opLabel) (\(formatValue(bytes, unit: "B")) B/\(r.opLabel))"
    } else if let events = r.allocEvents, let bytes = r.allocBytes {
        resources += " · allocs \(groupedInt(Double(events)))/pass (\(groupedInt(Double(bytes))) B)"
    }
    if let childRSS = r.childPeakRSSBytes {
        resources += " · child peak RSS \(groupedInt(Double(childRSS) / 1024)) KiB"
    } else {
        resources += " · peak-RSS Δ \(groupedInt(Double(r.peakRSSDeltaBytes) / 1024)) KiB"
    }
    print(resources)
    if let note = r.note {
        print("    note: \(note)")
    }
}
