// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// Shared machinery for the parity subcommands: repo-root resolution,
// deterministic randomness, parse-or-die option values, the streaming
// corpus reader (bounded memory at 13M rows), fixture loaders, the
// large-stack worker bridge, and console helpers.

import Foundation

/// Package root resolved from this source file's compile-time path, with a
/// working-directory fallback for relocated binaries. Locates
/// `Tests/Fixtures/` and `KNOWN-DEVIATIONS.md`.
public func repositoryRoot() -> URL {
    let compiled = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // SwiftFiltParityCore
        .deletingLastPathComponent() // Sources
        .deletingLastPathComponent() // <package root>
    if FileManager.default.fileExists(atPath: compiled.appendingPathComponent("Package.swift").path) {
        return compiled
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}

/// Absolute path of a demangling fixture (`Tests/Fixtures/SwiftDemangling/<name>`).
public func demanglingFixturePath(_ name: String) -> String {
    repositoryRoot().appendingPathComponent("Tests/Fixtures/SwiftDemangling/\(name)").path
}

/// Absolute path of a CLI fixture (`Tests/Fixtures/CLI/<subpath>`).
public func cliFixturePath(_ subpath: String) -> String {
    repositoryRoot().appendingPathComponent("Tests/Fixtures/CLI/\(subpath)").path
}

/// Absolute path of a census fixture (`Tests/Fixtures/Census/<name>`).
public func censusFixturePath(_ name: String) -> String {
    repositoryRoot().appendingPathComponent("Tests/Fixtures/Census/\(name)").path
}

/// Deterministic 64-bit generator (SplitMix64): seeded runs are
/// reproducible run to run and across platforms.
public struct SplitMix64: Sendable {
    public var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A uniform value in `0..<bound` (`bound` ≥ 1).
    public mutating func next(below bound: Int) -> Int {
        Int(next() % UInt64(max(1, bound)))
    }
}

public func eprint(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Thousands-grouped decimal for readable counts.
public func grouped(_ value: Int) -> String {
    var digits = Array(String(value))
    var out: [Character] = []
    var count = 0
    while let digit = digits.popLast() {
        if count > 0, count % 3 == 0, digit != "-" { out.append(",") }
        out.append(digit)
        count += 1
    }
    return String(out.reversed())
}

public func secondsText(_ interval: TimeInterval) -> String {
    interval < 100 ? String(format: "%.1fs", interval) : String(format: "%dm%02ds", Int(interval) / 60, Int(interval) % 60)
}

/// Parse a non-negative decimal option value or die loudly (exit 2) —
/// a value that fails to parse must never become a silent default.
public func parseCount(_ flag: String, in args: [String], at index: Int, for subcommand: String, minimum: Int = 0) -> Int {
    guard args.indices.contains(index), let value = Int(args[index]), value >= minimum else {
        eprint("\(subcommand): \(flag) needs a decimal value ≥ \(minimum)")
        exit(2)
    }
    return value
}

/// Parse a seed (decimal or 0x-prefixed hex) or die loudly.
public func parseSeed(_ flag: String, in args: [String], at index: Int, for subcommand: String) -> UInt64 {
    guard args.indices.contains(index) else {
        eprint("\(subcommand): \(flag) needs a value")
        exit(2)
    }
    let raw = args[index]
    let parsed = raw.hasPrefix("0x") ? UInt64(raw.dropFirst(2), radix: 16) : UInt64(raw)
    guard let seed = parsed else {
        eprint("\(subcommand): \(flag) value `\(raw)` is not a decimal or 0x-hex integer")
        exit(2)
    }
    return seed
}

/// Run `body` on a dedicated thread with a 128 MiB stack and await its
/// result. The recursive demangle / treeDump / print / remangle descend one
/// frame per tree level; the deepest real corpus symbols nest ~131 levels
/// and overflow the small cooperative-pool stack (a SIGBUS), exactly as
/// they do in `swift-demangle` without a large stack. The continuation
/// bridge keeps the caller inside structured concurrency.
public func onLargeStack<T: Sendable>(_ body: @Sendable @escaping () -> T) async -> T {
    await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        let thread = Thread { continuation.resume(returning: body()) }
        thread.stackSize = 128 << 20
        thread.start()
    }
}

// MARK: - Symbol sources

/// Streams column 0 (the mangled string) of a TSV manifest in batches,
/// reading fixed-size chunks so peak memory stays bounded regardless of the
/// 13M-row corpus size. `#`-prefixed lines and empty column-0 rows are
/// skipped and never counted.
public final class ManifestBatchReader {
    private let handle: FileHandle
    private let batchSize: Int
    private let limit: Int
    private var toSkip: Int
    private var buffer: [UInt8] = []
    private var offset = 0
    private var atEOF = false
    public private(set) var emittedCount = 0
    private let chunkBytes = 4 << 20

    /// `skip` discards that many would-be-emitted rows (comments and empty
    /// column-0 lines never count) before the first batch — the chunked
    /// acceptance driver's resume point. `limit` counts emitted rows only.
    public init?(path: String, batchSize: Int, limit: Int, skip: Int = 0) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        self.handle = handle
        self.batchSize = batchSize
        self.limit = limit
        toSkip = skip
    }

    deinit { try? handle.close() }

    private func refill() {
        if offset > 0 {
            buffer.removeFirst(offset)
            offset = 0
        }
        guard let data = (try? handle.read(upToCount: chunkBytes)) ?? nil, !data.isEmpty else {
            atEOF = true
            return
        }
        buffer.append(contentsOf: data)
    }

    private func nextLine() -> ArraySlice<UInt8>? {
        while true {
            var i = offset
            while i < buffer.count, buffer[i] != 0x0A {
                i += 1
            }
            if i < buffer.count {
                let line = buffer[offset ..< i]
                offset = i + 1
                return line
            }
            if atEOF {
                if offset < buffer.count {
                    let line = buffer[offset ..< buffer.count]
                    offset = buffer.count
                    return line
                }
                return nil
            }
            refill()
        }
    }

    /// The next batch of up to `batchSize` mangled strings, or `nil` when
    /// the manifest (or `limit`) is exhausted.
    public func next() -> [String]? {
        if emittedCount >= limit { return nil }
        var batch: [String] = []
        batch.reserveCapacity(batchSize)
        while batch.count < batchSize, emittedCount < limit {
            guard let line = nextLine() else { break }
            if line.first == 0x23 { continue } // '#' comment
            var end = line.startIndex
            while end < line.endIndex, line[end] != 0x09 {
                end += 1
            }
            let field = line[line.startIndex ..< end]
            if field.isEmpty { continue }
            if toSkip > 0 {
                toSkip -= 1
                continue
            }
            batch.append(String(decoding: field, as: UTF8.self))
            emittedCount += 1
        }
        return batch.isEmpty ? nil : batch
    }
}

/// The environment variable that switches the symbol source from the
/// committed fixtures to an external corpus manifest
/// (TSV, `mangled<TAB>first_binary<TAB>occurrences`).
public let corpusEnvironmentVariable = "SWIFTFILT_DEMANGLE_CORPUS"

/// Where a run's symbols come from — committed fixtures by default, the
/// external corpus manifest when `SWIFTFILT_DEMANGLE_CORPUS` is set.
public enum SymbolSource {
    case fixtures([String])
    case manifest(path: String)

    /// Resolve from the environment: the external manifest when the
    /// variable is set (a missing file is a loud setup error, never a
    /// silent fixture fallback), the committed fixtures otherwise.
    public static func resolve(for subcommand: String) -> SymbolSource? {
        if let path = ProcessInfo.processInfo.environment[corpusEnvironmentVariable] {
            guard FileManager.default.fileExists(atPath: path) else {
                eprint("\(subcommand): \(corpusEnvironmentVariable)=\(path) does not exist")
                return nil
            }
            return .manifest(path: path)
        }
        return .fixtures(fixtureSymbols())
    }

    public var descriptionLine: String {
        switch self {
        case let .fixtures(symbols): "committed fixtures (\(grouped(symbols.count)) symbols)"
        case let .manifest(path): "external corpus \(path)"
        }
    }
}

/// Every mangled string in the committed demangling fixtures (column 0 of
/// corpus.tsv, apple.tsv, and legacy.tsv), in file order, first occurrence
/// only (a symbol two fixtures share carries one verdict, not two rows).
public func fixtureSymbols() -> [String] {
    var symbols: [String] = []
    var seen: Set<String> = []
    for file in ["corpus.tsv", "apple.tsv", "legacy.tsv"] {
        guard let contents = try? String(contentsOfFile: demanglingFixturePath(file), encoding: .utf8) else { continue }
        for raw in contents.split(separator: "\n") {
            if raw.isEmpty || raw.hasPrefix("#") { continue }
            guard let tab = raw.firstIndex(of: "\t") else { continue }
            let symbol = String(raw[raw.startIndex ..< tab])
            if seen.insert(symbol).inserted {
                symbols.append(symbol)
            }
        }
    }
    return symbols
}

// MARK: - Fixture rows

/// One frozen row of `corpus.tsv`: the mangled name and the exact
/// `swift-demangle` outputs captured when the fixture was generated
/// (`-compact` / `-simplified` / `-no-sugar`).
public struct CorpusFixtureRow: Sendable {
    public let mangled: String
    public let compact: String
    public let simplified: String
    public let noSugar: String
    public let lineNumber: Int

    public init(mangled: String, compact: String, simplified: String, noSugar: String, lineNumber: Int) {
        self.mangled = mangled
        self.compact = compact
        self.simplified = simplified
        self.noSugar = noSugar
        self.lineNumber = lineNumber
    }
}

/// Load `corpus.tsv` (4 columns). Rows with any other column count are
/// returned separately so a malformed fixture is loud, never skipped.
public func loadCorpusFixture(path: String) throws -> (rows: [CorpusFixtureRow], malformedLines: [Int]) {
    let contents = try String(contentsOfFile: path, encoding: .utf8)
    var rows: [CorpusFixtureRow] = []
    var malformed: [Int] = []
    for (idx, raw) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        if raw.isEmpty || raw.hasPrefix("#") { continue }
        let parts = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 else {
            malformed.append(idx + 1)
            continue
        }
        rows.append(CorpusFixtureRow(mangled: parts[0], compact: parts[1], simplified: parts[2], noSugar: parts[3], lineNumber: idx + 1))
    }
    return (rows, malformed)
}

/// One frozen row of a two-column fixture (`apple.tsv`: mangled → expected
/// `.full` rendering).
public struct PairFixtureRow: Sendable {
    public let mangled: String
    public let expected: String
    public let lineNumber: Int

    public init(mangled: String, expected: String, lineNumber: Int) {
        self.mangled = mangled
        self.expected = expected
        self.lineNumber = lineNumber
    }
}

public func loadPairFixture(path: String) throws -> (rows: [PairFixtureRow], malformedLines: [Int]) {
    let contents = try String(contentsOfFile: path, encoding: .utf8)
    var rows: [PairFixtureRow] = []
    var malformed: [Int] = []
    for (idx, raw) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        if raw.isEmpty || raw.hasPrefix("#") { continue }
        let parts = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else {
            malformed.append(idx + 1)
            continue
        }
        rows.append(PairFixtureRow(mangled: parts[0], expected: parts[1], lineNumber: idx + 1))
    }
    return (rows, malformed)
}

/// One frozen row of `legacy.tsv` (mangled → `-compact` → `-simplified`).
public struct LegacyFixtureRow: Sendable {
    public let mangled: String
    public let compact: String
    public let simplified: String
    public let lineNumber: Int

    public init(mangled: String, compact: String, simplified: String, lineNumber: Int) {
        self.mangled = mangled
        self.compact = compact
        self.simplified = simplified
        self.lineNumber = lineNumber
    }
}

public func loadLegacyFixture(path: String) throws -> (rows: [LegacyFixtureRow], malformedLines: [Int]) {
    let contents = try String(contentsOfFile: path, encoding: .utf8)
    var rows: [LegacyFixtureRow] = []
    var malformed: [Int] = []
    for (idx, raw) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        if raw.isEmpty || raw.hasPrefix("#") { continue }
        let parts = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else {
            malformed.append(idx + 1)
            continue
        }
        rows.append(LegacyFixtureRow(mangled: parts[0], compact: parts[1], simplified: parts[2], lineNumber: idx + 1))
    }
    return (rows, malformed)
}

/// The oracle `-tree-only` blocks of `trees.txt` keyed by input symbol:
/// header `Demangling for <input>`, then the node lines, blank-separated.
public func loadTreeBlocks(path: String) throws -> [String: String] {
    let contents = try String(contentsOfFile: path, encoding: .utf8)
    var blocks: [String: String] = [:]
    var currentKey: String?
    var current: [Substring] = []
    func flush() {
        guard let key = currentKey else { return }
        while let last = current.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            current.removeLast()
        }
        blocks[key] = current.joined(separator: "\n")
        current.removeAll(keepingCapacity: true)
    }
    for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("Demangling for ") {
            flush()
            currentKey = String(line.dropFirst("Demangling for ".count))
            continue
        }
        if currentKey != nil { current.append(line) }
    }
    flush()
    return blocks
}

/// `swift-demangle` echoes its input back verbatim when it cannot demangle
/// a symbol (also with the one leading Mach-O `_` stripped). On that echo
/// the oracle declined — the comparison for that row belongs to the
/// decline-agreement leg, not the print legs.
public func oracleDeclined(_ oracleValue: String, mangled: String) -> Bool {
    if oracleValue == mangled { return true }
    if mangled.hasPrefix("_"), oracleValue == String(mangled.dropFirst()) { return true }
    return false
}

public extension String {
    func trimmedTrailingNewlines() -> String {
        var s = Substring(self)
        while let last = s.last, last == "\n" || last == "\r" {
            s = s.dropLast()
        }
        return String(s)
    }
}
