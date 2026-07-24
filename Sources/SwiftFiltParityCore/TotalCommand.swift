// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// `swiftfilt-parity total` — the totality battery: the public entry points
// must never crash, never hang, and return nil-or-valid on EVERY input,
// hostile ones first. Batteries (all sizes derive from `--items`, all
// randomness from the printed `--seed`):
//
//   random-bytes      arbitrary byte strings, invalid UTF-8 included
//   prefixed-garbage  every recognized mangling prefix + random tails
//   truncation        real corpus symbols cut at EVERY byte length
//   deep-nesting      generated deeply nested manglings (recursion floor)
//   huge              multi-megabyte inputs and absurd length claims
//   scanner-bytes     random byte soup through the byte scanner and
//                     `demangleAll(inBytes:)` — pass-through preservation
//   demangle-all      junk⟨symbol⟩junk lines through `demangleAll(in:)` —
//                     replacement exactness and junk preservation
//
// Contracts asserted per item: `demangle` returns nil or a non-empty
// string; `demangle(validating:)` throws exactly when `demangle` is nil;
// `demangle` non-nil implies `DemangledSymbol` parses; remangle and
// classify never crash; the scanner replaces only validated manglings and
// preserves every other byte. A per-item watchdog thread reports any item
// exceeding its budget WITH its reproducer (seed + battery + item) and
// terminates the run — a hang is a finding, never a stall.
//
// CRASH RESILIENCE: a Swift *runtime* trap (e.g. an engine index-out-of-
// range on a malformed tree) cannot be caught in-process — it kills the
// process, so an in-process battery cannot turn it into a divergence row.
// For crash-resilient enumeration run the battery in subprocess shards
// (`--battery <name> --from <n>`): a shard that exits >128 is a crash;
// bisect it with `--dump-items` (strictly serial — the last dumped line
// is the reproducer, printed as item index + base64), record it, and
// resume with `--from <item+1>`. Scripts/total-crash-sweep.sh drives this
// over every battery. The in-process default path stays the fast one for
// the common (no-crash) case.

import Foundation
import SwiftFilt

public func runTotalCommand(_ args: [String]) async -> Int32 {
    var items = 100_000
    var seed: UInt64 = 0x5F17_F117_0DD1_7135
    var itemTimeoutMs = 10000
    var jobs = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
    var inlineRows = 25
    var onlyBattery: String?
    var fromItem = 0
    var dumpItems = false
    var index = 0
    while index < args.count {
        switch args[index] {
        case "--items":
            index += 1
            items = parseCount("--items", in: args, at: index, for: "total", minimum: 100)
        case "--seed":
            index += 1
            seed = parseSeed("--seed", in: args, at: index, for: "total")
        case "--item-timeout-ms":
            index += 1
            itemTimeoutMs = parseCount("--item-timeout-ms", in: args, at: index, for: "total", minimum: 100)
        case "--jobs":
            index += 1
            jobs = parseCount("--jobs", in: args, at: index, for: "total", minimum: 1)
        case "--inline-rows":
            index += 1
            inlineRows = parseCount("--inline-rows", in: args, at: index, for: "total")
        case "--battery":
            // Deterministic re-drive of ONE battery (crash triage: a Swift
            // runtime trap kills the process before any label can print,
            // so the crashing item is found by bisecting a battery slice).
            index += 1
            onlyBattery = args.indices.contains(index) ? args[index] : nil
        case "--from":
            index += 1
            fromItem = parseCount("--from", in: args, at: index, for: "total")
        case "--dump-items":
            // Print each generated input (item index + base64) BEFORE
            // running it — the last dumped line before a crash IS the
            // reproducer, verbatim.
            dumpItems = true
        default:
            eprint("total: unknown option \(args[index])")
            return 2
        }
        index += 1
    }

    let catalogue = DeviationCatalogue.load()
    var report = RunReport(instrument: "total", catalogue: catalogue)
    report.note("seed: 0x\(String(seed, radix: 16)) (settable via --seed; every battery derives from it deterministically)")
    report.note("items base: \(grouped(items)) per --items; per-item watchdog: \(itemTimeoutMs)ms")
    print("[total] seed=0x\(String(seed, radix: 16)) items=\(grouped(items)) jobs=\(jobs) item-timeout=\(itemTimeoutMs)ms")

    let watchdog = ItemWatchdog(timeout: Double(itemTimeoutMs) / 1000, seed: seed)
    watchdog.start()
    defer { watchdog.stop() }

    // Truncation source: real symbols — the committed fixtures, or a
    // deterministic slice of the external corpus when the env var is set
    // (a bad path is a loud setup error, never a silent fixture fallback).
    guard let source = SymbolSource.resolve(for: "total") else { return 2 }
    var truncationSource = fixtureSymbols()
    switch source {
    case let .manifest(path):
        guard let reader = ManifestBatchReader(path: path, batchSize: 4096, limit: 40000) else {
            eprint("total: could not open \(path)")
            return 2
        }
        var external: [String] = []
        while let batch = reader.next() {
            external.append(contentsOf: batch)
        }
        guard !external.isEmpty else {
            eprint("total: \(path) yielded no symbols")
            return 2
        }
        truncationSource = external
        report.note("truncation source: first \(grouped(external.count)) corpus symbols (\(path))")
    case .fixtures:
        report.note("truncation source: committed fixtures (\(grouped(truncationSource.count)) symbols)")
    }

    let truncationPlan = TruncationPlan(symbols: truncationSource)
    let truncationCount = items * 3
    report.note("truncation pair space: \(grouped(truncationPlan.totalPairs)) (symbol × cut-length); \(truncationCount >= truncationPlan.totalPairs ? "items cover EVERY pair" : "items stride a coprime subset — raise --items to \(grouped((truncationPlan.totalPairs + 2) / 3)) for the full sweep")")

    var batteries: [(name: String, count: Int)] = [
        ("random-bytes", items * 2),
        ("prefixed-garbage", items * 2),
        ("truncation", truncationCount),
        ("deep-nesting", max(200, items / 50)),
        ("huge", max(24, items / 4000)),
        ("scanner-bytes", items / 2),
        ("demangle-all", items / 5),
    ]
    if let onlyBattery {
        batteries = batteries.filter { $0.name == onlyBattery }
        guard !batteries.isEmpty else {
            eprint("total: unknown battery `\(onlyBattery)`")
            return 2
        }
    }
    var localReport = report
    for battery in batteries {
        let started = Date()
        let failures = await runBattery(
            battery.name, count: battery.count, seed: seed, from: fromItem,
            truncationSource: truncationSource, truncationPlan: truncationPlan,
            jobs: jobs, watchdog: watchdog, dumpItems: dumpItems,
        )
        localReport.countComparison(leg: battery.name, by: battery.count)
        for failure in failures {
            localReport.record(failure)
        }
        print("[total] \(battery.name): \(grouped(battery.count)) items, \(failures.count) failure(s) [\(secondsText(Date().timeIntervalSince(started)))]")
    }
    report = localReport

    if let tsv = report.writeGatingRows(toDirectory: repositoryRoot().appendingPathComponent(".build/parity-reports").path) {
        report.note("gating rows TSV: \(tsv)")
    }
    print(report.render(inlineRowLimit: inlineRows))
    return report.exitCode
}

// MARK: - Watchdog

/// Per-item hang detection: workers check in before every item and out
/// after it; a monitor thread reports any item older than the budget with
/// its full reproducer and terminates the process (exit 4). A hung
/// demangle cannot be cancelled from outside, so a loud terminal report is
/// the only honest outcome — and the printed seed + item label reproduces
/// it deterministically.
public final class ItemWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight: [Int: (label: String, started: Date)] = [:]
    private var monitor: Thread?
    private var stopped = false
    private let timeout: Double
    private let seed: UInt64

    public init(timeout: Double, seed: UInt64) {
        self.timeout = timeout
        self.seed = seed
    }

    public func start() {
        let thread = Thread { [weak self] in
            while let self {
                lock.lock()
                if stopped {
                    lock.unlock()
                    return
                }
                let now = Date()
                for (_, item) in inFlight where now.timeIntervalSince(item.started) > timeout {
                    let age = now.timeIntervalSince(item.started)
                    lock.unlock()
                    eprint("total: WATCHDOG — item exceeded \(Int(timeout * 1000))ms (age \(String(format: "%.1f", age))s)")
                    eprint("total: reproducer: --seed 0x\(String(seed, radix: 16)) item: \(item.label)")
                    eprint("total: a hang is a finding; terminating the run")
                    exit(4)
                }
                lock.unlock()
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        thread.name = "parity-total-watchdog"
        monitor = thread
        thread.start()
    }

    public func stop() {
        lock.lock()
        stopped = true
        inFlight.removeAll()
        lock.unlock()
    }

    public func begin(slot: Int, label: String) {
        lock.lock()
        inFlight[slot] = (label, Date())
        lock.unlock()
    }

    public func end(slot: Int) {
        lock.lock()
        inFlight[slot] = nil
        lock.unlock()
    }
}

// MARK: - Battery driver

/// The flat (symbol × cut-length) pair space for the truncation battery:
/// every byte-length prefix of every source symbol, addressable by a
/// single pair index. Items walk it with a stride coprime to the space
/// size, so a budget ≥ the space visits EVERY pair exactly once and a
/// smaller budget spreads uniformly — never just the short prefixes.
public struct TruncationPlan: Sendable {
    let symbols: [[UInt8]]
    let cumulative: [Int]
    public let totalPairs: Int
    let stride: Int

    public init(symbols rawSymbols: [String]) {
        let bytes = rawSymbols.map { Array($0.utf8) }.filter { !$0.isEmpty }
        symbols = bytes
        var cumulative: [Int] = []
        cumulative.reserveCapacity(bytes.count)
        var total = 0
        for symbol in bytes {
            cumulative.append(total)
            total += symbol.count
        }
        self.cumulative = cumulative
        totalPairs = max(1, total)
        var candidate = 2_147_483_647 % totalPairs // 2^31 − 1 (prime)
        if candidate == 0 { candidate = 1 }
        while greatestCommonDivisor(candidate, totalPairs) != 1 {
            candidate += 1
        }
        stride = candidate
    }

    /// The truncated input for item `index`.
    public func input(for index: Int) -> String {
        guard !symbols.isEmpty else { return "$s4main3fooyyF" }
        let pair = (index % totalPairs) * stride % totalPairs
        // Last cumulative start ≤ pair.
        var low = 0
        var high = cumulative.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if cumulative[mid] <= pair {
                low = mid
            } else {
                high = mid - 1
            }
        }
        let cut = pair - cumulative[low] + 1
        return String(decoding: symbols[low].prefix(cut), as: UTF8.self)
    }
}

private func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
    var a = a
    var b = b
    while b != 0 {
        (a, b) = (b, a % b)
    }
    return a
}

private func runBattery(
    _ name: String, count: Int, seed: UInt64, from: Int, truncationSource: [String],
    truncationPlan: TruncationPlan, jobs: Int, watchdog: ItemWatchdog, dumpItems: Bool,
) async -> [Divergence] {
    // `--dump-items` triage runs strictly serially (one task, one item at
    // a time), so the LAST dumped line before a Swift-runtime trap is
    // unambiguously the crashing item — concurrency would interleave the
    // dumps of other in-flight workers and hide it.
    if dumpItems {
        return await onLargeStack {
            batteryItems(name, range: from ..< count, seed: seed, truncationSource: truncationSource, truncationPlan: truncationPlan, watchdog: watchdog, slot: 0, dumpItems: true)
        }
    }
    let chunk = max(1, count / (jobs * 8))
    return await withTaskGroup(of: [Divergence].self) { group in
        var start = from
        var slot = 0
        while start < count {
            let end = min(start + chunk, count)
            let range = start ..< end
            let workerSlot = slot
            group.addTask {
                await onLargeStack {
                    batteryItems(name, range: range, seed: seed, truncationSource: truncationSource, truncationPlan: truncationPlan, watchdog: watchdog, slot: workerSlot)
                }
            }
            start = end
            slot += 1
        }
        var failures: [Divergence] = []
        for await chunkFailures in group {
            failures.append(contentsOf: chunkFailures)
        }
        // Deterministic report order regardless of completion order.
        return failures.sorted { ($0.mangled, $0.klass) < ($1.mangled, $1.klass) }
    }
}

private func batteryItems(
    _ name: String, range: Range<Int>, seed: UInt64, truncationSource: [String],
    truncationPlan: TruncationPlan, watchdog: ItemWatchdog, slot: Int, dumpItems: Bool = false,
) -> [Divergence] {
    var failures: [Divergence] = []
    for item in range {
        // Item-keyed generator: reproducible independently of chunking.
        var rng = SplitMix64(seed: seed ^ (0x9E37 &* UInt64(item)) ^ UInt64(name.utf8.count))
        let label = "battery=\(name) item=\(item)"
        if dumpItems {
            let input = generatedInput(name, item: item, rng: rng, truncationPlan: truncationPlan)
            FileHandle.standardError.write(Data("[dump] \(label) input.b64=\(Data(input.utf8).base64EncodedString())\n".utf8))
        }
        watchdog.begin(slot: slot, label: label)
        switch name {
        case "random-bytes":
            let input = randomByteString(&rng, maxLength: 240)
            checkEntryPoints(input, item: item, into: &failures)
        case "prefixed-garbage":
            let input = prefixedGarbage(&rng)
            checkEntryPoints(input, item: item, into: &failures)
        case "truncation":
            let input = truncationPlan.input(for: item)
            checkEntryPoints(input, item: item, into: &failures)
        case "deep-nesting":
            let input = deeplyNested(&rng, item: item)
            checkEntryPoints(input, item: item, into: &failures, skipRemangle: false)
        case "huge":
            let input = hugeInput(&rng, item: item)
            checkEntryPoints(input, item: item, into: &failures)
        case "scanner-bytes":
            checkScannerBytes(&rng, item: item, into: &failures)
        case "demangle-all":
            checkDemangleAll(&rng, truncationSource: truncationSource, into: &failures)
        default:
            break
        }
        watchdog.end(slot: slot)
    }
    return failures
}

/// The generated input for a direct-input battery item (the ones whose
/// input is a pure function of name+item — every battery except
/// scanner-bytes/demangle-all, which consume the rng mid-item). Used only
/// by `--dump-items` triage so a crash's reproducer is printed verbatim.
private func generatedInput(_ name: String, item: Int, rng: SplitMix64, truncationPlan: TruncationPlan) -> String {
    var rng = rng
    switch name {
    case "random-bytes": return randomByteString(&rng, maxLength: 240)
    case "prefixed-garbage": return prefixedGarbage(&rng)
    case "truncation": return truncationPlan.input(for: item)
    case "deep-nesting": return deeplyNested(&rng, item: item)
    case "huge": return hugeInput(&rng, item: item)
    default: return "<battery \(name) generates its input inline>"
    }
}

// MARK: - Per-item contracts

/// The nil-or-valid contract across the public entry points, for one input.
private func checkEntryPoints(_ input: String, item: Int, into failures: inout [Divergence], skipRemangle: Bool = false) {
    func fail(_ klass: String, _ detail: String) {
        failures.append(Divergence(
            leg: "total", klass: klass, mangled: "item=\(item) input.prefix=\(String(input.prefix(80)))",
            swiftfilt: detail, oracle: "totality contract",
        ))
    }
    let demangled = demangle(input)
    if let demangled, demangled.isEmpty {
        fail("empty-demangle", "demangle returned an empty string (contract: nil or non-empty)")
    }
    // Taxonomy consistency: validating throws exactly when demangle is nil.
    do {
        let validated = try demangle(validating: input)
        if demangled == nil {
            fail("taxonomy-inconsistent", "demangle(validating:) succeeded (`\(validated.prefix(60))`) where demangle returned nil")
        }
    } catch {
        if demangled != nil {
            fail("taxonomy-inconsistent", "demangle(validating:) threw \(error) where demangle returned `\(demangled!.prefix(60))`")
        }
    }
    _ = isSwiftMangled(input) // must not crash on any input
    let symbol = DemangledSymbol(input)
    if demangled != nil, symbol == nil {
        fail("structure-inconsistent", "demangle succeeded but DemangledSymbol returned nil")
    }
    if let symbol {
        // Structure and renderings must be total for any parsed tree.
        _ = symbol.kind
        _ = symbol.module
        _ = symbol.identityKey
        let printer = SwiftDemanglerPrinter()
        for style in [SwiftDemanglerPrinter.Style.full, .simplified, .qualified, .unqualified] {
            _ = printer.print(symbol.symbol, style: style)
        }
        _ = printer.classify(input, demangled: symbol.symbol)
        if !skipRemangle {
            if let remangled = SwiftMangler().mangle(symbol.symbol), remangled.isEmpty {
                fail("empty-remangle", "remangle returned an empty string (contract: nil or non-empty)")
            }
        }
    }
}

/// Byte-scanner totality and pass-through: `demangleAll(inBytes:)` on
/// random soup (invalid UTF-8 included) must preserve every byte outside
/// validated manglings — and with no matches, the output IS the input.
private func checkScannerBytes(_ rng: inout SplitMix64, item: Int, into failures: inout [Divergence]) {
    var bytes: [UInt8] = []
    let length = rng.next(below: 600)
    bytes.reserveCapacity(length)
    for _ in 0 ..< length {
        bytes.append(UInt8(truncatingIfNeeded: rng.next()))
    }
    let scanner = MangledNameScanner()
    let matches = scanner.matches(inBytes: bytes)
    let rewritten = scanner.demangleAll(inBytes: bytes, style: .full)
    if matches.isEmpty, rewritten != bytes {
        failures.append(Divergence(
            leg: "total", klass: "passthrough-violation", mangled: "item=\(item) bytes=\(bytes.count)",
            swiftfilt: "demangleAll changed \(rewritten.count)-byte output with zero matches",
            oracle: "no-match input must round-trip byte-for-byte",
        ))
    }
    for match in matches {
        let rendered = match.demangled(.full)
        if rendered.isEmpty {
            failures.append(Divergence(
                leg: "total", klass: "empty-match-render", mangled: match.mangled,
                swiftfilt: "<empty .full render for a validated scanner match>", oracle: "matches demangle non-empty",
            ))
        }
    }
}

/// `demangleAll(in:)` exactness: junk⟨real symbol⟩junk must rewrite the
/// symbol to its `demangle()` form and preserve the junk byte-for-byte.
private func checkDemangleAll(_ rng: inout SplitMix64, truncationSource: [String], into failures: inout [Divergence]) {
    let junkAlphabet = Array(" \t/:-+=%!^&*()[]{}<>~#|;.,")
    func junk(_ n: Int) -> String {
        var out = ""
        for _ in 0 ..< n {
            out.append(junkAlphabet[rng.next(below: junkAlphabet.count)])
        }
        return out
    }
    let symbol = truncationSource.isEmpty ? "$s4main3fooyyF" : truncationSource[rng.next(below: truncationSource.count)]
    guard let expected = demangle(symbol) else { return } // non-demangling rows pass through; covered above
    let head = junk(rng.next(below: 40))
    let tail = junk(rng.next(below: 40))
    let line = head + symbol + tail
    let rewritten = demangleAll(in: line)
    let want = head + expected + tail
    if rewritten != want {
        failures.append(Divergence(
            leg: "total", klass: "demangleall-mismatch", mangled: symbol,
            swiftfilt: rewritten, oracle: want,
        ))
    }
}

// MARK: - Generators

private func randomByteString(_ rng: inout SplitMix64, maxLength: Int) -> String {
    let length = rng.next(below: maxLength + 1)
    var bytes: [UInt8] = []
    bytes.reserveCapacity(length)
    for _ in 0 ..< length {
        bytes.append(UInt8(truncatingIfNeeded: rng.next()))
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// Every recognized mangling-prefix era + a random tail: half drawn from
/// the mangling character set (plausible garbage), half raw bytes.
private func prefixedGarbage(_ rng: inout SplitMix64) -> String {
    let prefixes = ["$s", "$S", "_$s", "_$S", "$e", "_$e", "_T0", "_T", "_Tt", "__T", "@__swiftmacro_", "_T0027"]
    let prefix = prefixes[rng.next(below: prefixes.count)]
    let manglingAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_$")
    let length = rng.next(below: 120)
    var tail = ""
    if rng.next(below: 2) == 0 {
        for _ in 0 ..< length {
            tail.append(manglingAlphabet[rng.next(below: manglingAlphabet.count)])
        }
    } else {
        var bytes: [UInt8] = []
        for _ in 0 ..< length {
            bytes.append(UInt8(truncatingIfNeeded: rng.next()))
        }
        tail = String(decoding: bytes, as: UTF8.self)
    }
    return prefix + tail
}

/// Deeply nested manglings: valid nesting operators stacked to depths that
/// found the recursion floor in the reference demangler.
private func deeplyNested(_ rng: inout SplitMix64, item: Int) -> String {
    let depth = 16 + rng.next(below: 1600)
    switch item % 4 {
    case 0: // nested arrays: $s Say Say … Si GGG…
        return "$s" + String(repeating: "Say", count: depth) + "Si" + String(repeating: "G", count: depth)
    case 1: // nested optionals: $s Si Sg Sg …
        return "$sSi" + String(repeating: "Sg", count: depth)
    case 2: // nested metatypes on the old grammar
        return "_Tt" + String(repeating: "M", count: depth) + "Si"
    default: // nested function types: unbalanced hostile tail
        return "$s" + String(repeating: "yyc", count: depth) + "fU_"
    }
}

/// Multi-megabyte inputs and absurd embedded length claims.
private func hugeInput(_ rng: inout SplitMix64, item: Int) -> String {
    switch item % 4 {
    case 0: // huge length claim with a short body
        return "$s99999999A"
    case 1: // a megabyte of a single identifier
        return "$s1000000" + String(repeating: "A", count: 1_000_000)
    case 2: // two megabytes of mangling-alphabet noise
        var out = "$s"
        out.reserveCapacity(2_000_002)
        var localRng = rng
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        for _ in 0 ..< 2_000_000 {
            out.append(alphabet[localRng.next(below: alphabet.count)])
        }
        return out
    default: // a long run of substitution markers
        return "$sSS" + String(repeating: "AA", count: 500_000)
    }
}
