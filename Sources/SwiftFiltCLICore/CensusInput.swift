// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// Census input: detect what kind of symbol listing stdin is and parse it
// into rows. Three formats — bare text (scanner matches), nm output
// (BSD/llvm-nm, with or without a size column), and Xcode LinkMap files.
// Every input line lands in exactly one ledger bucket; nothing is
// silently dropped — the parse is itself part of the census's honesty
// contract, and `CensusTally` re-asserts the tiling.

import SwiftFilt

/// The census input formats. `bare` is the fallback: any text, every
/// validated mangling counted per occurrence.
@frozen
public enum CensusFormat: String, Sendable, Hashable, CaseIterable {
    /// Arbitrary text: validated manglings found by the scanner, one count
    /// per occurrence. Count-weighted.
    case bare
    /// `nm` output: one symbol per line (`address type name`, or
    /// `address size type name` from `llvm-nm --print-size` on formats
    /// that carry sizes). Size-weighted when a size column exists.
    case nm
    /// An Xcode/ld link map (`-Xlinker -map`): full parse of the
    /// `# Symbols:` and `# Dead Stripped Symbols:` sections with object
    /// file ordinal mapping. Size-weighted.
    case linkmap
}

/// One symbol row harvested from the input: the name as the tool printed
/// it, and its size when the format carries one.
public struct CensusRow: Sendable, Hashable {
    /// The symbol name, byte-for-byte as listed (leading Mach-O
    /// underscores and linker suffixes included).
    public var name: String
    /// The row's size in bytes, when the input carries a size column.
    public var size: UInt64?

    public init(name: String, size: UInt64? = nil) {
        self.name = name
        self.size = size
    }
}

/// The parsed input: rows plus the full line ledger. Every input line is
/// counted in exactly one bucket — `structureLines` (headers, tables,
/// blanks), one `rows` element, one dead-stripped row, or
/// `unparseableLines` — so the census can prove it dropped nothing.
/// What each row's *name* is (Swift, non-Swift, content atom, malformed)
/// is ``CensusTally``'s job, not the parser's.
public struct CensusHarvest: Sendable {
    /// Which format was parsed.
    public var format: CensusFormat
    /// One sentence of detection reasoning (why this format was chosen,
    /// or that it was forced by `--format`).
    public var detectionReason: String
    /// Total input lines (a final unterminated line counts).
    public var lines: Int
    /// Scaffolding lines: linkmap headers/section/object-file tables,
    /// nm arch headers, blank lines.
    public var structureLines: Int
    /// Lines that should have parsed as rows but did not — counted and
    /// reported, never dropped.
    public var unparseableLines: Int
    /// The live rows (bare: one per validated mangling occurrence). The
    /// staged parse (``CensusInput/harvest(_:format:reason:)``) fills this;
    /// the census CLI's fused parse+tally pipeline
    /// (``CensusInput/harvestAndTally(_:format:reason:)``) classifies each
    /// row as it parses and leaves this empty — at a million rows the
    /// retained staging was a large share of peak memory — so row-count
    /// arithmetic reads ``rowCount``, which both paths maintain.
    public var rows: [CensusRow]
    /// The number of live rows parsed — authoritative for the ledgers and
    /// tiling checks (equals `rows.count` on the staged path; carries the
    /// count alone on the fused path, which stages nothing).
    public var rowCount: Int
    /// Bytes of all live rows, summed at parse time — the tally
    /// re-derives this from its classification buckets and the two must
    /// tile exactly.
    public var rowBytes: UInt64
    /// Dead-stripped rows (linkmap only): counted and byte-totaled, never
    /// mixed into the live population (they are not in the binary).
    public var deadRowCount: Int
    /// Bytes of the dead-stripped rows.
    public var deadRowBytes: UInt64
    /// Whether any row carried a size (selects bytes weighting).
    public var sizesPresent: Bool
    /// Live rows with no size in an input where sizes are present (nm
    /// undefined rows in a `--print-size` dump).
    public var rowsWithoutSize: Int
    /// nm rows whose type character is `U`/`u` — references, not
    /// definitions, flagged so the population is read honestly.
    public var undefinedRows: Int
    /// The linkmap `# Path:` value.
    public var path: String?
    /// The linkmap `# Arch:` value.
    public var arch: String?
    /// Linkmap object files, by ordinal.
    public var objectFiles: [Int: String]
    /// Linkmap rows whose file ordinal is not in the object-file table
    /// (still counted as rows; surfaced because it means the map is
    /// inconsistent).
    public var unknownOrdinalRows: Int

    public init(format: CensusFormat, detectionReason: String) {
        self.format = format
        self.detectionReason = detectionReason
        lines = 0
        structureLines = 0
        unparseableLines = 0
        rows = []
        rowCount = 0
        rowBytes = 0
        deadRowCount = 0
        deadRowBytes = 0
        sizesPresent = false
        rowsWithoutSize = 0
        undefinedRows = 0
        path = nil
        arch = nil
        objectFiles = [:]
        unknownOrdinalRows = 0
    }

    /// Fold `other` into this harvest — the additive combine behind parallel
    /// census over line-aligned shards. Every ledger counter sums and byte
    /// totals saturating-add, so the merged ledger equals the whole-input
    /// parse's. ``rowsWithoutSize`` is the one non-additive field: it is
    /// defined as `0` unless a size column is present, so a shard that
    /// happened to hold only sizeless rows reports `0` there while all its
    /// rows are in fact unsized. Each side's *raw* unsized count is
    /// recovered (`sizesPresent ? rowsWithoutSize : rowCount` — a sizeless
    /// shard's rows are all unsized), summed, and re-gated on the merged
    /// `sizesPresent`, which makes the field exact and the merge associative
    /// however the shard boundaries fall. The linkmap-only fields carry
    /// through (empty on the bare/nm formats this parallelizes).
    public func merged(with other: CensusHarvest) -> CensusHarvest {
        var result = self
        result.lines += other.lines
        result.structureLines += other.structureLines
        result.unparseableLines += other.unparseableLines
        result.rows += other.rows
        result.rowCount += other.rowCount
        result.rowBytes = CensusInput.saturatingAdd(result.rowBytes, other.rowBytes)
        result.deadRowCount += other.deadRowCount
        result.deadRowBytes = CensusInput.saturatingAdd(result.deadRowBytes, other.deadRowBytes)
        result.undefinedRows += other.undefinedRows
        result.unknownOrdinalRows += other.unknownOrdinalRows
        let selfRawUnsized = sizesPresent ? rowsWithoutSize : rowCount
        let otherRawUnsized = other.sizesPresent ? other.rowsWithoutSize : other.rowCount
        result.sizesPresent = sizesPresent || other.sizesPresent
        result.rowsWithoutSize = result.sizesPresent ? selfRawUnsized + otherRawUnsized : 0
        result.path = path ?? other.path
        result.arch = arch ?? other.arch
        for (ordinal, file) in other.objectFiles {
            result.objectFiles[ordinal] = file
        }
        return result
    }
}

/// Format detection and the three parsers.
public enum CensusInput {
    // MARK: Detection

    /// How many leading non-blank lines the nm detector samples. All of
    /// them must parse as nm rows (arch headers allowed) — one prose line
    /// in the sample resolves the input to bare text.
    public static let detectionSampleLimit = 200

    /// Detect the input format from content. A forced format skips
    /// detection but still records why. The rules, in order: a first
    /// non-blank line starting `# Path:` is a linkmap (ld writes that
    /// header first); an input whose first ``detectionSampleLimit``
    /// non-blank lines all parse as nm rows (fat-binary arch headers
    /// allowed) with at least one real row is nm output; anything else —
    /// including anything ambiguous — is bare text, and the reason says
    /// what was seen.
    public static func detect(lines: [String], forced: CensusFormat?) -> (format: CensusFormat, reason: String) {
        if let forced {
            return (forced, "format forced by --format \(forced.rawValue)")
        }
        guard let first = lines.first(where: { !$0.isEmpty }) else {
            return (.bare, "empty input; treated as bare text")
        }
        if first.hasPrefix("# Path:") {
            return (.linkmap, "first line is an ld '# Path:' header")
        }
        var sampled = 0
        var nmRows = 0
        for line in lines where !line.isEmpty {
            if sampled == detectionSampleLimit { break }
            sampled += 1
            if parseNmRow(line) != nil {
                nmRows += 1
            } else if !isNmArchHeader(line) {
                return (.bare, "no linkmap header and line \(sampled) of the sample is not an nm row; treated as bare text")
            }
        }
        if nmRows > 0 {
            return (.nm, "all \(sampled) sampled lines are nm rows")
        }
        return (.bare, "no linkmap header and no nm rows in the sample; treated as bare text")
    }

    /// Walk the input line by line — `\n`-delimited, one trailing `\r`
    /// stripped (Windows nm dumps), each line decoded as UTF-8 with invalid
    /// sequences replaced — WITHOUT retaining the lines: `body` sees each
    /// decoded line and may stop the walk by returning `false`. A trailing
    /// newline does not invent an empty final line. The structured parsers
    /// stream through here, so a million-line listing never materializes a
    /// million-`String` array (``splitLines(_:)`` is the retaining form).
    static func forEachLine(_ bytes: [UInt8], _ body: (String) -> Bool) {
        var start = 0
        let newline = UInt8(ascii: "\n")
        let carriage = UInt8(ascii: "\r")
        var index = 0
        while index < bytes.count {
            if bytes[index] == newline {
                var end = index
                if end > start, bytes[end - 1] == carriage { end -= 1 }
                guard body(String(decoding: bytes[start ..< end], as: UTF8.self)) else { return }
                start = index + 1
            }
            index += 1
        }
        if start < bytes.count {
            var end = bytes.count
            if bytes[end - 1] == carriage { end -= 1 }
            _ = body(String(decoding: bytes[start ..< end], as: UTF8.self))
        }
    }

    /// Split raw input bytes into retained lines — the walk of
    /// ``forEachLine(_:_:)``, collected (detection samples and tests use
    /// this; the census pipeline streams instead).
    public static func splitLines(_ bytes: [UInt8]) -> [String] {
        var result: [String] = []
        forEachLine(bytes) { line in
            result.append(line)
            return true
        }
        return result
    }

    /// Detect from raw bytes: decode only the detection sample (the first
    /// ``detectionSampleLimit`` non-blank lines plus any leading blanks),
    /// never the whole input, and apply exactly the ``detect(lines:forced:)``
    /// rules to it — every rule reads only the sample, so the verdicts and
    /// reasons are identical.
    public static func detect(_ bytes: [UInt8], forced: CensusFormat?) -> (format: CensusFormat, reason: String) {
        if let forced {
            return (forced, "format forced by --format \(forced.rawValue)")
        }
        var sample: [String] = []
        var nonBlank = 0
        forEachLine(bytes) { line in
            sample.append(line)
            if !line.isEmpty { nonBlank += 1 }
            return nonBlank < detectionSampleLimit
        }
        return detect(lines: sample, forced: nil)
    }

    /// Parse `bytes` in `format` (already detected or forced), staging
    /// every live row in ``CensusHarvest/rows``.
    public static func harvest(
        _ bytes: [UInt8],
        format: CensusFormat,
        reason: String,
    ) -> CensusHarvest {
        var rows: [CensusRow] = []
        var harvest = harvestCore(bytes, format: format, reason: reason) { name, size in
            rows.append(CensusRow(name: name, size: size))
        }
        harvest.rows = rows
        return harvest
    }

    /// The fused census pipeline: one pass that parses each row and hands
    /// it straight to the tally's classifier — no `[String]` line array, no
    /// `[CensusRow]` staging, so peak memory is the input buffer plus the
    /// aggregation tables. Books: the harvest's ledger fields accumulate at
    /// parse time exactly as the staged path's do (same core), and the
    /// tally's tiling checks compare against them unchanged.
    public static func harvestAndTally(
        _ bytes: [UInt8],
        format: CensusFormat,
        reason: String,
    ) -> (harvest: CensusHarvest, tally: CensusTally) {
        var builder = CensusTally.Builder(format: format)
        let harvest = harvestCore(bytes, format: format, reason: reason) { name, size in
            builder.add(name: name, sizeBytes: size)
        }
        return (harvest, builder.finish())
    }

    /// The one parse implementation behind both forms: walks `bytes` in
    /// `format`, accumulates every ``CensusHarvest`` ledger field, and
    /// reports each live row to `onRow` (name as the tool printed it, size
    /// when the format carries one) instead of staging it.
    static func harvestCore(
        _ bytes: [UInt8],
        format: CensusFormat,
        reason: String,
        onRow: (String, UInt64?) -> Void,
    ) -> CensusHarvest {
        switch format {
        case .bare: harvestBare(bytes, reason: reason, onRow: onRow)
        case .nm: harvestNm(bytes, reason: reason, onRow: onRow)
        case .linkmap: harvestLinkMap(bytes, reason: reason, onRow: onRow)
        }
    }

    // MARK: Bare text

    /// Bare text: every validated mangling is one count-weighted row. The
    /// scan is the library's byte scanner — binary-safe, so a bare census
    /// accepts anything a pipe carries.
    static func harvestBare(_ bytes: [UInt8], reason: String, onRow: (String, UInt64?) -> Void) -> CensusHarvest {
        var harvest = CensusHarvest(format: .bare, detectionReason: reason)
        harvest.lines = lineCount(bytes)
        let scanner = MangledNameScanner()
        for match in scanner.matches(inBytes: bytes) {
            harvest.rowCount += 1
            onRow(match.mangled, nil)
        }
        return harvest
    }

    /// The number of lines ``splitLines(_:)`` would return, without
    /// decoding any: one per `\n`, plus a final unterminated fragment.
    static func lineCount(_ bytes: [UInt8]) -> Int {
        var count = 0
        let newline = UInt8(ascii: "\n")
        for byte in bytes where byte == newline {
            count += 1
        }
        if let last = bytes.last, last != newline { count += 1 }
        return count
    }

    // MARK: nm output

    /// One parsed nm row: the symbol type character, the name, and the
    /// size when the dump carries a size column.
    struct NmRow {
        var typeCharacter: Character
        var name: String
        var size: UInt64?
    }

    /// Parse one nm line. Shapes (name may contain spaces, so it is the
    /// unsplit remainder):
    ///
    ///     <hex-address> <type> <name>              BSD/llvm-nm
    ///     <hex-address> <hex-size> <type> <name>   llvm-nm --print-size
    ///     <spaces> <type> <name>                   undefined (no address)
    ///
    /// The size shape requires the second field to be at least two hex
    /// digits — a single hex letter there (`d`, `b`, …) is a type
    /// character of the unsized shape, never a size.
    static func parseNmRow(_ line: String) -> NmRow? {
        // Undefined shape: leading whitespace, then a type char.
        if let firstNonSpace = line.firstIndex(where: { $0 != " " }), firstNonSpace != line.startIndex {
            return parseTypeAndName(line[firstNonSpace...], size: nil)
        }
        guard let addressEnd = line.firstIndex(of: " "), isHex(line[..<addressEnd]) else { return nil }
        let afterAddress = line[line.index(after: addressEnd)...]
        // Sized shape: second field is 2+ hex digits and a type char follows.
        if let sizeEnd = afterAddress.firstIndex(of: " "),
           afterAddress.distance(from: afterAddress.startIndex, to: sizeEnd) >= 2,
           isHex(afterAddress[..<sizeEnd]),
           let row = parseTypeAndName(
               afterAddress[afterAddress.index(after: sizeEnd)...],
               size: UInt64(afterAddress[..<sizeEnd], radix: 16),
           )
        {
            return row
        }
        return parseTypeAndName(afterAddress, size: nil)
    }

    /// `<type> <name>` — a single type character (letter, `-`, or `?`),
    /// one space, then the name (the rest of the line, spaces included).
    private static func parseTypeAndName(_ text: Substring, size: UInt64?) -> NmRow? {
        guard let typeCharacter = text.first, isNmTypeCharacter(typeCharacter) else { return nil }
        let afterType = text.dropFirst()
        guard afterType.first == " " else { return nil }
        let name = afterType.dropFirst()
        guard !name.isEmpty else { return nil }
        return NmRow(typeCharacter: typeCharacter, name: String(name), size: size)
    }

    /// nm symbol-type characters: the letter classes plus `-` (debugger
    /// stabs) and `?` (unknown). A `switch`, not an `||` chain: the chain
    /// compiles each disjunct to its own autoclosure that reads as an
    /// uncovered region until a witness of that exact class appears.
    private static func isNmTypeCharacter(_ character: Character) -> Bool {
        switch character {
        case "a" ... "z", "A" ... "Z", "-", "?": true
        default: false
        }
    }

    /// Non-empty and entirely hex digits.
    private static func isHex(_ text: Substring) -> Bool {
        !text.isEmpty && text.allSatisfy(\.isHexDigit)
    }

    /// `nm` on a fat binary separates slices with
    /// `<path> (for architecture <arch>):` headers.
    static func isNmArchHeader(_ line: String) -> Bool {
        line.hasSuffix("):") && containsASCII(line, " (for architecture ")
    }

    /// Byte-level substring search (`String.contains(_:)` needs a newer
    /// platform floor than the package promises; census needles are pure
    /// ASCII, so byte equality is exact).
    static func containsASCII(_ text: String, _ needle: String) -> Bool {
        let haystack = Array(text.utf8)
        let pattern = Array(needle.utf8)
        guard pattern.count <= haystack.count, !pattern.isEmpty else { return false }
        for start in 0 ... (haystack.count - pattern.count)
            where haystack[start ..< start + pattern.count].elementsEqual(pattern)
        {
            return true
        }
        return false
    }

    /// nm output: one row per parsed line; blank lines and fat-binary
    /// arch headers are structure; anything else is unparseable.
    static func harvestNm(_ bytes: [UInt8], reason: String, onRow: (String, UInt64?) -> Void) -> CensusHarvest {
        var harvest = CensusHarvest(format: .nm, detectionReason: reason)
        var unsizedRows = 0
        forEachLine(bytes) { line in
            harvest.lines += 1
            if line.isEmpty || isNmArchHeader(line) {
                harvest.structureLines += 1
                return true
            }
            guard let row = parseNmRow(line) else {
                harvest.unparseableLines += 1
                return true
            }
            if row.typeCharacter == "U" || row.typeCharacter == "u" {
                harvest.undefinedRows += 1
            }
            if let size = row.size {
                harvest.sizesPresent = true
                harvest.rowBytes = saturatingAdd(harvest.rowBytes, size)
            } else {
                unsizedRows += 1
            }
            harvest.rowCount += 1
            onRow(row.name, row.size)
            return true
        }
        // A sized dump's unsized rows (undefined symbols carry no size)
        // are only worth flagging when sizes are the weighting.
        if harvest.sizesPresent {
            harvest.rowsWithoutSize = unsizedRows
        }
        return harvest
    }

    // MARK: LinkMap

    /// The linkmap section being read; rows mean different things in each.
    private enum LinkMapSection {
        case preamble, objectFiles, sections, symbols, deadStripped
    }

    /// An Xcode/ld link map. Header lines switch sections; `# Object
    /// files:` rows build the ordinal→file map; `# Symbols:` rows are the
    /// live population; `# Dead Stripped Symbols:` rows are counted apart
    /// (they are not in the binary).
    static func harvestLinkMap(_ bytes: [UInt8], reason: String, onRow: (String, UInt64?) -> Void) -> CensusHarvest {
        var harvest = CensusHarvest(format: .linkmap, detectionReason: reason)
        var section = LinkMapSection.preamble
        forEachLine(bytes) { line in
            harvest.lines += 1
            if line.hasPrefix("#") {
                harvest.structureLines += 1
                if line.hasPrefix("# Path: ") {
                    harvest.path = String(line.dropFirst("# Path: ".count))
                } else if line.hasPrefix("# Arch: ") {
                    harvest.arch = String(line.dropFirst("# Arch: ".count))
                } else if line.hasPrefix("# Object files:") {
                    section = .objectFiles
                } else if line.hasPrefix("# Sections:") {
                    section = .sections
                } else if line.hasPrefix("# Symbols:") {
                    section = .symbols
                } else if line.hasPrefix("# Dead Stripped Symbols:") {
                    section = .deadStripped
                }
                return true
            }
            if line.isEmpty {
                harvest.structureLines += 1
                return true
            }
            switch section {
            case .preamble:
                // Content before any header: not a linkmap's shape —
                // counted loudly (forced-format misuse lands here).
                harvest.unparseableLines += 1
            case .objectFiles:
                if let entry = parseObjectFileRow(line) {
                    harvest.objectFiles[entry.ordinal] = entry.path
                    harvest.structureLines += 1
                } else {
                    harvest.unparseableLines += 1
                }
            case .sections:
                // The section table is scaffolding: its sizes are whole
                // sections, which would double-count the symbol rows.
                harvest.structureLines += 1
            case .symbols, .deadStripped:
                guard let row = parseLinkMapRow(line, dead: section == .deadStripped) else {
                    harvest.unparseableLines += 1
                    return true
                }
                if row.ordinal.map({ harvest.objectFiles[$0] == nil }) == true {
                    harvest.unknownOrdinalRows += 1
                }
                harvest.sizesPresent = true
                if section == .deadStripped {
                    harvest.deadRowCount += 1
                    harvest.deadRowBytes = saturatingAdd(harvest.deadRowBytes, row.size)
                } else {
                    harvest.rowBytes = saturatingAdd(harvest.rowBytes, row.size)
                    harvest.rowCount += 1
                    onRow(row.name, row.size)
                }
            }
            return true
        }
        return harvest
    }

    /// One `# Object files:` row: `[  N] path`.
    static func parseObjectFileRow(_ line: String) -> (ordinal: Int, path: String)? {
        // `Substring(line)`, not `line[...]`: the unbounded-range subscript
        // compiles to an uncoverable phantom autoclosure.
        guard let (ordinal, rest) = parseOrdinal(Substring(line)) else { return nil }
        return (ordinal, String(rest))
    }

    /// One parsed symbol/dead row.
    struct LinkMapRow {
        var name: String
        var size: UInt64
        var ordinal: Int?
    }

    /// Parse `<address>\t<size>\t[  N] <name>`. `address` is `0x…` hex in
    /// the live section and `<<dead>>` in the dead-stripped section; a row
    /// in the wrong section's shape does not parse. The name is the
    /// remainder — linkmap names carry spaces (`literal string: …`,
    /// `_symbolic …`).
    static func parseLinkMapRow(_ line: String, dead: Bool) -> LinkMapRow? {
        guard let addressEnd = line.firstIndex(of: "\t") else { return nil }
        let address = line[..<addressEnd]
        if dead {
            // ld pads the dead marker to the address column with spaces.
            guard address.hasPrefix("<<dead>>") else { return nil }
        } else {
            guard address.hasPrefix("0x"), isHex(address.dropFirst(2)) else { return nil }
        }
        let afterAddress = line[line.index(after: addressEnd)...]
        guard let sizeEnd = afterAddress.firstIndex(of: "\t") else { return nil }
        let sizeField = afterAddress[..<sizeEnd]
        guard sizeField.hasPrefix("0x"), let size = UInt64(sizeField.dropFirst(2), radix: 16) else { return nil }
        let fileAndName = afterAddress[afterAddress.index(after: sizeEnd)...]
        guard let (ordinal, name) = parseOrdinal(fileAndName), !name.isEmpty else { return nil }
        return LinkMapRow(name: String(name), size: size, ordinal: ordinal)
    }

    /// Parse a leading `[  N] ` ordinal; returns the ordinal and the rest.
    private static func parseOrdinal(_ text: Substring) -> (ordinal: Int, rest: Substring)? {
        guard text.first == "[", let close = text.firstIndex(of: "]") else { return nil }
        let digits = text[text.index(after: text.startIndex) ..< close].filter { $0 != " " }
        guard let ordinal = Int(digits), ordinal >= 0 else { return nil }
        var rest = text[text.index(after: close)...]
        guard rest.first == " " else { return nil }
        rest = rest.dropFirst()
        return (ordinal, rest)
    }

    // MARK: Content atoms

    /// Whether a row name is linker content rather than a symbol: the
    /// grounded ld64/ld-prime map vocabulary (literal pools, unwind
    /// scaffolding, ObjC/CF literals, `_symbolic` reflection refs) plus
    /// assembler-local `l…` labels. Everything unrecognized stays a
    /// symbol row — counted, never dropped — so an unknown future form
    /// can only surface, not vanish. ``CensusTally`` consults this only
    /// AFTER the demangle checks, so a local label wrapping a real
    /// mangling (`l_$s…Hr` conformance/type records) stays a Swift row.
    static func isContentAtomName(_ name: String) -> Bool {
        if name.hasPrefix("literal string: ") { return true }
        if name.hasPrefix("_symbolic ") { return true }
        if name.hasPrefix("FDE for: ") || name.hasPrefix("LSDA for: ") { return true }
        if name.hasPrefix("non-lazy-pointer-to-local: ") || name.hasPrefix("lazy-pointer-to-local: ") { return true }
        if name == "anon" || name == "CIE" || name == "CFString" || name == "compact unwind info" { return true }
        // 4-byte-literal / 8-byte-literal / 16-byte-literal literal pools.
        if name.hasSuffix("-byte-literal"), name.dropLast("-byte-literal".count).allSatisfy(\.isNumber) {
            return true
        }
        // Assembler-local labels: `l_.str.…`, `l___unnamed_…`,
        // `l_entry_point`, `ltmp…` ("literal string: " was matched above,
        // so the one-letter prefix cannot swallow it).
        if name.hasPrefix("l"), name.count > 1 { return true }
        return false
    }

    /// Sum sizes without a crash on hostile inputs: saturate at
    /// `UInt64.max` (a map claiming 2^64 total bytes fails the tally's
    /// tiling checks loudly instead of trapping here).
    static func saturatingAdd(_ total: UInt64, _ addend: UInt64) -> UInt64 {
        let (sum, overflow) = total.addingReportingOverflow(addend)
        return overflow ? .max : sum
    }
}
