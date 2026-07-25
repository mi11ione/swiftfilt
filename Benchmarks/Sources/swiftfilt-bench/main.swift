// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// swiftfilt-bench — the benchmark battery. Modes:
//
//   all        every section below, in order (default)
//   demangle | stream | filter | structure — the swiftfilt battery
//   compare    batch throughput, every contender, identical batch
//   latency    single-symbol latency, every contender
//   coverage   correctness coverage vs the frozen ground truth
//   cli        wall + child peak RSS on the 64 MiB log, CLI contenders
//   card       the benchmark card's full ingredient list in one run:
//              demangle → filter → compare → latency → coverage → cli
//   smoke      the nightly regression smoke: short stream + filter
//              (100k-symbol target, 16 MiB log, 3 runs unless
//              overridden); with --baseline FILE compares medians
//              one-sided against the checked-in thresholds and exits 1
//              on breach
//
// Contenders (each at its documented best case): swiftfilt one-shot ·
// swiftfilt DemangleSession · `swift-demangle` subprocess ·
// dlsym("swift_demangle") · CwlDemangle · Runtime.demangle (SE-0498,
// where the host can run it — otherwise the exact reason prints).
//
// Options: --json (results document to stdout, progress to stderr) ·
// --runs N · --mib N (filter/cli log size) · --seed 0xHEX|decimal ·
// --symbols N (cap the loaded stream) · --baseline FILE
//
// Methodology: every benchmark runs unrecorded warmups (1, except
// where a benchmark's note documents more) + `runs` recorded runs;
// reported figure = MEDIAN, spread = (max−min)/median. Inputs are
// deterministic from the seed and the committed fixtures (recipe in
// Workloads.swift); SWIFTFILT_DEMANGLE_CORPUS swaps in an external
// corpus manifest. Always run via
// `swift run -c release swiftfilt-bench` — debug numbers are
// meaningless and the tool warns on stderr. Run it FOREGROUND: macOS
// gives background-launched process groups efficiency-core scheduling,
// which roughly halves every number.

import Foundation
import SwiftFilt

// MARK: - Argument parsing (fail-loud)

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("swiftfilt-bench: \(message)\n".utf8))
    exit(2)
}

struct BenchConfig {
    var json = false
    var runs = 5
    var logMiB = 64
    var seed: UInt64 = 0xC_0FFE_E001_5BAD
    var symbolCap: Int?
    var baselinePath: String?
    var censusWorkload = "session"
    var censusSymbol = "$s4main3fooyyF"
    var censusCalls = 2000
}

var modes: [String] = []
var config = BenchConfig()
var explicitMiB: Int?
var explicitRuns: Int?

var argIterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIterator.next() {
    switch arg {
    case "--json":
        config.json = true
    case "--runs", "--mib", "--seed", "--symbols", "--baseline", "--census-workload", "--census-symbol", "--census-calls":
        guard let value = argIterator.next() else { die("\(arg) requires a value") }
        switch arg {
        case "--runs":
            guard let n = Int(value), n >= 1 else { die("--runs: invalid value '\(value)'") }
            explicitRuns = n
        case "--mib":
            guard let n = Int(value), n >= 1 else { die("--mib: invalid value '\(value)'") }
            explicitMiB = n
        case "--seed":
            let parsed = value.hasPrefix("0x")
                ? UInt64(value.dropFirst(2), radix: 16)
                : UInt64(value)
            guard let s = parsed else { die("--seed: invalid value '\(value)'") }
            config.seed = s
        case "--symbols":
            guard let n = Int(value), n >= 1 else { die("--symbols: invalid value '\(value)'") }
            config.symbolCap = n
        case "--census-workload":
            guard value == "session" || value == "oneshot" else { die("--census-workload: 'session' or 'oneshot', not '\(value)'") }
            config.censusWorkload = value
        case "--census-symbol":
            config.censusSymbol = value
        case "--census-calls":
            guard let n = Int(value), n >= 1, n <= 100_000 else { die("--census-calls: invalid value '\(value)' (1…100000)") }
            config.censusCalls = n
        default:
            config.baselinePath = value
        }
    case "all", "demangle", "stream", "filter", "structure", "compare", "latency", "coverage", "cli", "card", "smoke", "alloc-census":
        modes.append(arg)
    default:
        die("unknown argument '\(arg)' (modes: all demangle stream filter structure compare latency coverage cli card smoke alloc-census; options: --json --runs --mib --seed --symbols --baseline --census-workload --census-symbol --census-calls)")
    }
}

if modes.isEmpty { modes = ["all"] }
let isSmoke = modes.contains("smoke")
config.runs = explicitRuns ?? (isSmoke ? 3 : 5)
config.logMiB = explicitMiB ?? (isSmoke ? 16 : 64)

// The allocation-site census runs alone: it hooks the process allocator,
// so interleaving it with timing benchmarks would poison both.
if modes.contains("alloc-census") {
    guard modes == ["alloc-census"] else { die("alloc-census runs alone (it hooks the allocator)") }
    runAllocCensus(workload: config.censusWorkload, symbol: config.censusSymbol, calls: config.censusCalls)
    exit(0)
}

let machine = MachineInfo.capture()

@MainActor func progress(_ message: String) {
    if config.json {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    } else {
        print(message)
    }
}

#if DEBUG
    progress("WARNING: debug build — numbers are meaningless; use swift run -c release swiftfilt-bench")
#endif

progress("swiftfilt-bench: \(machine.cpuBrand), \(machine.physicalCores) cores (\(machine.performanceCores.map(String.init) ?? "?")P+\(machine.efficiencyCores.map(String.init) ?? "?")E), \(machine.memoryBytes / (1024 * 1024 * 1024)) GiB")

let stream = loadSymbolStream(cap: config.symbolCap)
let symbols = stream.symbols
guard !symbols.isEmpty else { die("symbol stream is empty") }
progress("symbols: \(stream.sourceDescription)")
progress("config: seed 0x\(String(config.seed, radix: 16)), runs \(config.runs), filter log \(config.logMiB) MiB")

/// Sections the `card` composite mode runs — everything the benchmark
/// card's tables cite, reproducible with one command.
let cardSections: Set<String> = ["demangle", "filter", "compare", "latency", "coverage", "cli"]

@MainActor func wants(_ mode: String) -> Bool {
    modes.contains(mode) || modes.contains("all") || (modes.contains("card") && cardSections.contains(mode))
}

var results: [BenchResult] = []
var coverageResults: [CoverageResult] = []

// MARK: - (a) single-symbol demangle latency

// Two anchors: a short everyday function symbol, and the stream's
// longest symbol (deterministic given the input) as the deep-generic
// worst-ish case. ns/op = wall over `iterations` sequential calls.
if wants("demangle") {
    progress("demangle-simple / demangle-complex…")
    let simple = "$s4main3fooyyF"
    let complex = symbols.max(by: { $0.utf8.count < $1.utf8.count })!
    func latency(name: String, symbol: String, iterations: Int) -> BenchResult {
        measure(
            name: name, unit: "ns/op", largerIsBetter: false, runs: config.runs,
            opsPerRun: Double(iterations),
            note: "\(iterations) sequential demangle(_:) calls of a \(symbol.utf8.count)-byte mangling",
        ) {
            var folded: UInt64 = 0
            let seconds = timed {
                for _ in 0 ..< iterations {
                    if let output = demangle(symbol) {
                        folded &+= foldString(output)
                    }
                }
            }
            blackhole(folded)
            return seconds / Double(iterations) * 1e9
        }
    }
    results.append(latency(name: "demangle-simple", symbol: simple, iterations: 200_000))
    results.append(latency(name: "demangle-complex", symbol: complex, iterations: 2000))
}

// MARK: - (b) corpus-stream throughput

if wants("stream") || isSmoke {
    progress("stream-throughput…")
    let targetCalls = isSmoke ? 100_000 : 400_000
    let repeats = max(1, targetCalls / symbols.count)
    let callsPerRun = repeats * symbols.count
    results.append(measure(
        name: "stream-throughput", unit: "symbols/s", largerIsBetter: true, runs: config.runs,
        opsPerRun: Double(callsPerRun), opLabel: "symbol",
        note: "demangle(_:) over the full stream ×\(repeats) (\(groupedInt(Double(callsPerRun))) calls/run); every symbol real-world",
    ) {
        var resolved = 0
        var folded: UInt64 = 0
        let seconds = timed {
            for _ in 0 ..< repeats {
                for symbol in symbols {
                    if let output = demangle(symbol) {
                        resolved += 1
                        folded &+= foldString(output)
                    }
                }
            }
        }
        blackhole(folded &+ UInt64(resolved))
        return Double(callsPerRun) / seconds
    })

    // The amortized twin: the identical workload through ONE
    // DemangleSession — the number a batch caller (crash SDK, symbol
    // table pass) actually experiences. The session persists across
    // warmup and recorded runs, so the recorded figure (and the hooked
    // allocation pass) is the engine's steady state: per-call allocations
    // are the input copy and output string, never engine construction.
    // Reported, never baseline-gated; smoke stays the one-shot metric.
    if !isSmoke {
        progress("session-throughput…")
        let session = DemangleSession()
        results.append(measure(
            name: "session-throughput", unit: "symbols/s", largerIsBetter: true, runs: config.runs,
            opsPerRun: Double(callsPerRun), opLabel: "symbol",
            note: "DemangleSession.demangle(_:) over the full stream ×\(repeats) through one session (\(groupedInt(Double(callsPerRun))) calls/run); steady state — engine storage amortized, peak-RSS Δ includes the session's one-time buildup",
        ) {
            var resolved = 0
            var folded: UInt64 = 0
            let seconds = timed {
                for _ in 0 ..< repeats {
                    for symbol in symbols {
                        if let output = session.demangle(symbol) {
                            resolved += 1
                            folded &+= foldString(output)
                        }
                    }
                }
            }
            blackhole(folded &+ UInt64(resolved))
            return Double(callsPerRun) / seconds
        })
    }
}

// MARK: - (c) filter throughput on a synthetic log

if wants("filter") || isSmoke {
    progress("filter-throughput (\(config.logMiB) MiB synthetic log)…")
    let log = makeSyntheticLog(byteCount: config.logMiB * 1024 * 1024, seed: config.seed, symbols: symbols)
    let scanner = MangledNameScanner()
    let megabytes = Double(log.count) / 1_000_000
    results.append(measure(
        name: "filter-throughput", unit: "MB/s", largerIsBetter: true, runs: config.runs, warmups: 3,
        opsPerRun: megabytes, opLabel: "MB",
        note: "MangledNameScanner.demangleAll(inBytes:) over a \(groupedInt(Double(log.count)))-byte log; half the lines carry one mangling (MB = 10^6 bytes); 3 warmups (cold page-in dominates the first passes)",
    ) {
        var outputBytes = 0
        let seconds = timed {
            let rewritten = scanner.demangleAll(inBytes: log)
            outputBytes = rewritten.count
        }
        blackhole(UInt64(outputBytes))
        return megabytes / seconds
    })
}

// MARK: - (d) structured access: parse, identity key, curated fields

if wants("structure") {
    progress("parse-structured / identity-key / field-access…")
    results.append(measure(
        name: "parse-structured", unit: "ns/op", largerIsBetter: false, runs: config.runs,
        opsPerRun: Double(symbols.count),
        note: "DemangledSymbol(_:) over the full stream (\(groupedInt(Double(symbols.count))) parses/run)",
    ) {
        var parsed = 0
        let seconds = timed {
            for symbol in symbols {
                if let value = DemangledSymbol(symbol) {
                    parsed += 1
                    blackhole(UInt64(value.mangledName.utf8.count))
                }
            }
        }
        blackhole(UInt64(parsed))
        return seconds / Double(symbols.count) * 1e9
    })

    let parsed = symbols.compactMap { DemangledSymbol($0) }
    progress("  (\(parsed.count) of \(symbols.count) parse; field costs measured on those)")
    results.append(measure(
        name: "identity-key", unit: "ns/op", largerIsBetter: false, runs: config.runs,
        opsPerRun: Double(parsed.count),
        note: "identityKey derivation on \(groupedInt(Double(parsed.count))) pre-parsed symbols (normalize + qualified render)",
    ) {
        var folded: UInt64 = 0
        let seconds = timed {
            for symbol in parsed {
                folded &+= foldString(symbol.identityKey.rawValue)
            }
        }
        blackhole(folded)
        return seconds / Double(parsed.count) * 1e9
    })
    results.append(measure(
        name: "field-access", unit: "ns/op", largerIsBetter: false, runs: config.runs,
        opsPerRun: Double(parsed.count),
        note: "one op = kind + isStatic + module + path + name on a pre-parsed symbol (fields are computed on access by design)",
    ) {
        var folded: UInt64 = 0
        let seconds = timed {
            for symbol in parsed {
                folded &+= UInt64(symbol.kind == .function ? 1 : 0)
                folded &+= UInt64(symbol.isStatic ? 1 : 0)
                folded &+= UInt64(symbol.module?.utf8.count ?? 0)
                folded &+= UInt64(symbol.path.count)
                folded &+= UInt64(symbol.name?.utf8.count ?? 0)
            }
        }
        blackhole(folded)
        return seconds / Double(parsed.count) * 1e9
    })
}

// MARK: - (e) engine comparison: in-process vs subprocess vs runtime hook

if wants("compare") {
    progress("compare (swiftfilt vs swift-demangle vs dlsym vs CwlDemangle vs Runtime.demangle)…")
    let batch = symbols
    let batchNote = "same \(groupedInt(Double(batch.count)))-symbol batch for every contender"

    var resolvedInProcess = 0
    results.append(measure(
        name: "compare-swiftfilt", unit: "symbols/s", largerIsBetter: true, runs: config.runs,
        opsPerRun: Double(batch.count), opLabel: "symbol",
        note: "in-process demangle(_:); \(batchNote)",
    ) {
        var resolved = 0
        var folded: UInt64 = 0
        let seconds = timed {
            for symbol in batch {
                if let output = demangle(symbol) {
                    resolved += 1
                    folded &+= foldString(output)
                }
            }
        }
        blackhole(folded)
        resolvedInProcess = resolved
        return Double(batch.count) / seconds
    })
    progress("  swiftfilt resolved \(resolvedInProcess)/\(batch.count)")

    // The amortized in-process engine on the same batch: what a batch
    // caller holding one session gets, directly comparable against the
    // dlsym hook row (which is likewise setup-free per call).
    let compareSession = DemangleSession()
    results.append(measure(
        name: "compare-session", unit: "symbols/s", largerIsBetter: true, runs: config.runs,
        opsPerRun: Double(batch.count), opLabel: "symbol",
        note: "in-process DemangleSession.demangle(_:), one session for the whole batch; \(batchNote)",
    ) {
        var resolved = 0
        var folded: UInt64 = 0
        let seconds = timed {
            for symbol in batch {
                if let output = compareSession.demangle(symbol) {
                    resolved += 1
                    folded &+= foldString(output)
                }
            }
        }
        blackhole(folded)
        return Double(batch.count) / seconds
    })

    if let subprocess = SubprocessDemangler.locate() {
        let stdinData = Data((batch.joined(separator: "\n") + "\n").utf8)
        var subprocessOK = true
        results.append(measure(
            name: "compare-subprocess", unit: "symbols/s", largerIsBetter: true, runs: config.runs,
            opsPerRun: Double(batch.count), opLabel: "symbol",
            cpuScope: .children, countAllocations: false,
            note: "one raw-posix_spawn `swift-demangle -compact` per run, whole batch via stdin (spawn + pipe I/O amortized over the batch; CPU figures are the CHILD's — the engine's own cost; child-side allocations are unobservable from here); \(batchNote)",
        ) {
            let seconds = timed {
                if subprocess.demangleBatch(stdinData, expectedLines: batch.count) == nil {
                    subprocessOK = false
                }
            }
            return Double(batch.count) / seconds
        })
        if !subprocessOK {
            progress("  WARNING: subprocess run failed or misaligned — compare-subprocess numbers are invalid")
        } else {
            progress("  subprocess: \(subprocess.path)")
        }
    } else {
        progress("  compare-subprocess SKIPPED: swift-demangle not found (PATH, swiftc sibling, xcrun)")
    }

    if let hook = RuntimeHookDemangler.locate() {
        var resolvedByHook = 0
        results.append(measure(
            name: "compare-dlsym", unit: "symbols/s", largerIsBetter: true, runs: config.runs,
            opsPerRun: Double(batch.count), opLabel: "symbol",
            note: "dlsym(\"swift_demangle\") from the loaded runtime, one call + free per symbol; \(batchNote)",
        ) {
            var resolved = 0
            let seconds = timed {
                for symbol in batch {
                    if hook.demangle(symbol) != nil {
                        resolved += 1
                    }
                }
            }
            resolvedByHook = resolved
            return Double(batch.count) / seconds
        })
        progress("  dlsym hook resolved \(resolvedByHook)/\(batch.count) (string-only; declines the eras it does not speak)")
    } else {
        progress("  compare-dlsym SKIPPED: swift_demangle not resolvable in this process")
    }

    var resolvedByCwl = 0
    results.append(measure(
        name: "compare-cwl", unit: "symbols/s", largerIsBetter: true, runs: config.runs,
        opsPerRun: Double(batch.count), opLabel: "symbol",
        note: "CwlDemangle parseMangledSwiftSymbol(_:).description, one call per symbol; a thrown parse error is a decline; \(batchNote)",
    ) {
        var resolved = 0
        var folded: UInt64 = 0
        let seconds = timed {
            for symbol in batch {
                if let output = CwlContender.demangle(symbol) {
                    resolved += 1
                    folded &+= foldString(output)
                }
            }
        }
        blackhole(folded)
        resolvedByCwl = resolved
        return Double(batch.count) / seconds
    })
    progress("  CwlDemangle resolved \(resolvedByCwl)/\(batch.count) (rendering agreement is the coverage census's job)")

    if let reason = RuntimeAPIContender.unavailableReason {
        progress("  compare-runtime SKIPPED: \(reason)")
    } else {
        var resolvedByRuntime = 0
        results.append(measure(
            name: "compare-runtime", unit: "symbols/s", largerIsBetter: true, runs: config.runs,
            opsPerRun: Double(batch.count), opLabel: "symbol",
            note: "Runtime.demangle(_:) (SE-0498), one call per symbol; a thrown error is a decline; \(batchNote)",
        ) {
            var resolved = 0
            var folded: UInt64 = 0
            let seconds = timed {
                for symbol in batch {
                    if let output = RuntimeAPIContender.demangle(symbol) {
                        resolved += 1
                        folded &+= foldString(output)
                    }
                }
            }
            blackhole(folded)
            resolvedByRuntime = resolved
            return Double(batch.count) / seconds
        })
        progress("  Runtime.demangle resolved \(resolvedByRuntime)/\(batch.count)")
    }
}

// MARK: - (f) single-symbol latency, every contender

// The identical everyday symbol through each contender, identical
// iteration discipline — the card's latency column. swiftfilt's own
// one-shot number is `demangle-simple` above (same symbol, same
// discipline); these rows are the other contenders.
if wants("latency") {
    progress("latency (single everyday symbol, every contender)…")
    let simple = "$s4main3fooyyF"

    let latencySession = DemangleSession()
    results.append(measure(
        name: "latency-session", unit: "ns/op", largerIsBetter: false, runs: config.runs,
        opsPerRun: 200_000,
        note: "200,000 sequential DemangleSession.demangle(_:) calls of the \(simple.utf8.count)-byte everyday symbol through one warm session",
    ) {
        var folded: UInt64 = 0
        let seconds = timed {
            for _ in 0 ..< 200_000 {
                if let output = latencySession.demangle(simple) {
                    folded &+= foldString(output)
                }
            }
        }
        blackhole(folded)
        return seconds / 200_000 * 1e9
    })

    if let hook = RuntimeHookDemangler.locate() {
        results.append(measure(
            name: "latency-dlsym", unit: "ns/op", largerIsBetter: false, runs: config.runs,
            opsPerRun: 200_000,
            note: "200,000 sequential dlsym(\"swift_demangle\") calls (one call + free each) of the everyday symbol",
        ) {
            var folded: UInt64 = 0
            let seconds = timed {
                for _ in 0 ..< 200_000 {
                    if let length = hook.demangle(simple) {
                        folded &+= UInt64(length)
                    }
                }
            }
            blackhole(folded)
            return seconds / 200_000 * 1e9
        })
    } else {
        progress("  latency-dlsym SKIPPED: swift_demangle not resolvable in this process")
    }

    results.append(measure(
        name: "latency-cwl", unit: "ns/op", largerIsBetter: false, runs: config.runs,
        opsPerRun: 50000,
        note: "50,000 sequential CwlDemangle parseMangledSwiftSymbol(_:).description calls of the everyday symbol",
    ) {
        var folded: UInt64 = 0
        let seconds = timed {
            for _ in 0 ..< 50000 {
                if let output = CwlContender.demangle(simple) {
                    folded &+= foldString(output)
                }
            }
        }
        blackhole(folded)
        return seconds / 50000 * 1e9
    })

    if let reason = RuntimeAPIContender.unavailableReason {
        progress("  latency-runtime SKIPPED: \(reason)")
    } else {
        results.append(measure(
            name: "latency-runtime", unit: "ns/op", largerIsBetter: false, runs: config.runs,
            opsPerRun: 200_000,
            note: "200,000 sequential Runtime.demangle(_:) (SE-0498) calls of the everyday symbol",
        ) {
            var folded: UInt64 = 0
            let seconds = timed {
                for _ in 0 ..< 200_000 {
                    if let output = RuntimeAPIContender.demangle(simple) {
                        folded &+= foldString(output)
                    }
                }
            }
            blackhole(folded)
            return seconds / 200_000 * 1e9
        })
    }

    if let subprocess = SubprocessDemangler.locate() {
        var spawnOK = true
        results.append(measure(
            name: "latency-subprocess-spawn", unit: "ns/op", largerIsBetter: false, runs: config.runs,
            opsPerRun: 50, cpuScope: .children, countAllocations: false,
            note: "50 raw posix_spawns of `swift-demangle -compact <symbol>`, one per call — the spawn-per-symbol pattern scripts write; CPU figures are the CHILD's (rusage children delta)",
        ) {
            let seconds = timed {
                for _ in 0 ..< 50 {
                    if subprocess.demangleArguments([simple])?.count != 1 {
                        spawnOK = false
                    }
                }
            }
            return seconds / 50 * 1e9
        })
        if !spawnOK {
            progress("  WARNING: a spawn failed — latency-subprocess-spawn numbers are invalid")
        }
    } else {
        progress("  latency-subprocess-spawn SKIPPED: swift-demangle not found (PATH, swiftc sibling, xcrun)")
    }
}

// MARK: - (g) correctness coverage vs the frozen ground truth

if wants("coverage") {
    progress("coverage (every contender vs the committed fixture renderings)…")
    let groundTruth = loadGroundTruth()
    let subprocessTool = SubprocessDemangler.locate()
    // Secondary oracle for the convention split: the tool's --no-sugar
    // rendering of every symbol (the runtime engine's display style).
    let noSugar = subprocessTool.map { loadNoSugarTruth(tool: $0, groundTruth: groundTruth) } ?? [:]
    if noSugar.isEmpty {
        progress("  note: --no-sugar secondary oracle unavailable — misses will not be split into convention vs divergence")
    }
    coverageResults.append(censusInProcess(
        contender: "swiftfilt",
        configuration: "demangle(_:) one-shot — DemangleSession and the CLI run the same engine, held byte-identical by the corpus differential",
        groundTruth: groundTruth,
        noSugar: noSugar,
    ) { demangle($0) })
    if let tool = subprocessTool {
        if let census = censusSubprocess(tool: tool, groundTruth: groundTruth, noSugar: noSugar) {
            coverageResults.append(census)
        } else {
            progress("  swift-demangle coverage FAILED (spawn or line-count misalignment) — no census row")
        }
    } else {
        progress("  swift-demangle coverage SKIPPED: tool not found")
    }
    if let hook = RuntimeHookDemangler.locate() {
        coverageResults.append(censusInProcess(
            contender: "dlsym hook",
            configuration: "dlsym(\"swift_demangle\") from the loaded runtime, one call + free per symbol; NULL = decline",
            groundTruth: groundTruth,
            noSugar: noSugar,
        ) { hook.demangledString($0) })
    } else {
        progress("  dlsym coverage SKIPPED: swift_demangle not resolvable in this process")
    }
    coverageResults.append(censusInProcess(
        contender: "CwlDemangle",
        configuration: CwlContender.configuration + " (" + CwlContender.pin + ")",
        groundTruth: groundTruth,
        noSugar: noSugar,
    ) { CwlContender.demangle($0) })
    if let reason = RuntimeAPIContender.unavailableReason {
        progress("  Runtime.demangle coverage SKIPPED: \(reason)")
    } else {
        coverageResults.append(censusInProcess(
            contender: "Runtime.demangle",
            configuration: RuntimeAPIContender.configuration,
            groundTruth: groundTruth,
            noSugar: noSugar,
        ) { RuntimeAPIContender.demangle($0) })
    }
    if !config.json {
        printCoverage(coverageResults, groundTruth: groundTruth)
    }
}

// MARK: - (h) CLI wall + child peak RSS on the synthetic log

if wants("cli") {
    progress("cli (\(config.logMiB) MiB log through each CLI contender)…")
    let log = makeSyntheticLog(byteCount: config.logMiB * 1024 * 1024, seed: config.seed, symbols: symbols)
    let megabytes = Double(log.count) / 1_000_000
    let logPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("swiftfilt-bench-cli-\(ProcessInfo.processInfo.processIdentifier).log").path
    guard FileManager.default.createFile(atPath: logPath, contents: Data(log)) else {
        die("cli: cannot write the log to \(logPath)")
    }
    defer { try? FileManager.default.removeItem(atPath: logPath) }

    func cliRow(name: String, binary: String, arguments: [String], note: String) {
        var passOK = true
        var result = measure(
            name: name, unit: "s", largerIsBetter: false, runs: config.runs,
            opsPerRun: megabytes, opLabel: "MB",
            cpuScope: .children, countAllocations: false,
            note: note + "; \(groupedInt(Double(log.count)))-byte log via stdin (regular file), stdout to /dev/null; CPU figures are the CHILD's (rusage children delta); child peak RSS from one unrecorded /usr/bin/time -l pass",
        ) {
            guard let wall = runCLIPass(binary: binary, arguments: arguments, stdinPath: logPath) else {
                passOK = false
                return Double.infinity
            }
            return wall
        }
        result.childPeakRSSBytes = measureCLIChildPeakRSS(binary: binary, arguments: arguments, stdinPath: logPath)
        results.append(result)
        if !passOK {
            progress("  WARNING: a \(name) pass failed — its numbers are invalid")
        }
    }

    if let swiftfiltCLI = locateSwiftfiltCLI() {
        cliRow(
            name: "cli-swiftfilt-parallel", binary: swiftfiltCLI, arguments: [],
            note: "`swiftfilt < log` — saturated input engages the parallel rewrite (default: one worker per CPU), byte-identical ordered output",
        )
        cliRow(
            name: "cli-swiftfilt-jobs1", binary: swiftfiltCLI, arguments: ["--jobs", "1"],
            note: "`swiftfilt --jobs 1 < log` — the single-thread CLI wall",
        )
    } else {
        progress("  cli-swiftfilt-* SKIPPED: release binary missing — build it: (cd .. && swift build -c release --product swiftfilt)")
    }
    if let subprocess = SubprocessDemangler.locate() {
        cliRow(
            name: "cli-swift-demangle", binary: subprocess.path, arguments: [],
            note: "`swift-demangle < log` — the toolchain filter's only form (single-thread)",
        )
    } else {
        progress("  cli-swift-demangle SKIPPED: swift-demangle not found (PATH, swiftc sibling, xcrun)")
    }
}

// MARK: - Output

if config.json {
    var pairs: [(String, String)] = [
        ("symbols", stream.sourceDescription),
        ("seed", "0x" + String(config.seed, radix: 16)),
        ("runs", String(config.runs)),
        ("filterLogMiB", String(config.logMiB)),
    ]
    pairs.append(("modes", modes.joined(separator: ",")))
    print(renderJSON(machine: machine, config: pairs, results: results, coverage: coverageResults))
} else {
    print("\nresults (median over \(config.runs) runs, warmups unrecorded):")
    for result in results {
        printResult(result)
    }
}

// MARK: - Baseline comparison (the nightly regression guard)

if let baselinePath = config.baselinePath {
    let outcome = compareToBaseline(results: results, baselinePath: baselinePath, progress: progress)
    exit(outcome ? 0 : 1)
}

/// One-sided comparison against the checked-in baseline: throughput
/// metrics fail when median < baseline × (1 − tolerance); latency
/// metrics fail when median > baseline × (1 + tolerance). Every metric
/// listed in the baseline MUST be present in the run (a silently
/// missing metric is a failure, not a skip). Metrics the run produced
/// but the baseline does not list are reported, never gating.
@MainActor func compareToBaseline(results: [BenchResult], baselinePath: String, progress: (String) -> Void) -> Bool {
    guard let data = FileManager.default.contents(atPath: baselinePath) else {
        progress("baseline: cannot read \(baselinePath)")
        return false
    }
    guard
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        let metrics = root["metrics"] as? [String: [String: Any]],
        let tolerance = (root["toleranceFraction"] as? NSNumber)?.doubleValue
    else {
        progress("baseline: malformed JSON at \(baselinePath)")
        return false
    }
    if let hostClass = root["hostClass"] as? String {
        progress("baseline: \(baselinePath) (host class: \(hostClass), tolerance ±\(Int(tolerance * 100))%)")
    }
    var pass = true
    for (name, entry) in metrics.sorted(by: { $0.key < $1.key }) {
        guard
            let baselineMedian = (entry["median"] as? NSNumber)?.doubleValue,
            let largerIsBetter = entry["largerIsBetter"] as? Bool
        else {
            progress("baseline: FAIL \(name) — malformed entry")
            pass = false
            continue
        }
        guard let result = results.first(where: { $0.name == name }) else {
            progress("baseline: FAIL \(name) — metric missing from this run")
            pass = false
            continue
        }
        let measured = result.median
        if largerIsBetter {
            let floor = baselineMedian * (1 - tolerance)
            if measured < floor {
                progress("baseline: FAIL \(name) — \(formatValue(measured, unit: result.unit)) \(result.unit) < floor \(formatValue(floor, unit: result.unit)) (baseline \(formatValue(baselineMedian, unit: result.unit)))")
                pass = false
            } else {
                progress("baseline: PASS \(name) — \(formatValue(measured, unit: result.unit)) \(result.unit) ≥ floor \(formatValue(floor, unit: result.unit))")
            }
        } else {
            let ceiling = baselineMedian * (1 + tolerance)
            if measured > ceiling {
                progress("baseline: FAIL \(name) — \(formatValue(measured, unit: result.unit)) \(result.unit) > ceiling \(formatValue(ceiling, unit: result.unit)) (baseline \(formatValue(baselineMedian, unit: result.unit)))")
                pass = false
            } else {
                progress("baseline: PASS \(name) — \(formatValue(measured, unit: result.unit)) \(result.unit) ≤ ceiling \(formatValue(ceiling, unit: result.unit))")
            }
        }
    }
    for result in results where metrics[result.name] == nil {
        progress("baseline: note — \(result.name) not in baseline (not gating)")
    }
    progress(pass ? "baseline: PASS" : "baseline: BREACH")
    return pass
}
