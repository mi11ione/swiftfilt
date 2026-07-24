// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// The census aggregation: classify every harvested row through the real
// demangler and accumulate the population tables. The classification is
// the library's corpus-validated `DemangledSymbol`; this file owns only
// arithmetic — and asserts its own books balance (`violations(against:)`)
// so a bucket can never silently leak.

import SwiftFilt

/// One census cell: how many rows, and how many bytes where the input
/// carries sizes.
public struct CensusWeight: Sendable, Hashable {
    public var count: Int
    public var bytes: UInt64

    public init(count: Int = 0, bytes: UInt64 = 0) {
        self.count = count
        self.bytes = bytes
    }

    /// Accumulate one row (saturating on hostile byte totals; the tiling
    /// checks surface saturation as an imbalance rather than a trap).
    public mutating func add(bytes rowBytes: UInt64) {
        count += 1
        bytes = CensusInput.saturatingAdd(bytes, rowBytes)
    }

    /// Fold another cell in — the associative, commutative combine that
    /// merges two shards' tallies (counts add, bytes saturating-add, exactly
    /// as ``add(bytes:)`` accumulates one row at a time).
    public mutating func combine(_ other: CensusWeight) {
        count += other.count
        bytes = CensusInput.saturatingAdd(bytes, other.bytes)
    }
}

/// How one row name classified.
public enum CensusClassification: Sendable, Hashable {
    /// The name demangles (directly, or behind the assembler-local `l`
    /// prefix ld map rows carry); the payload is the parsed symbol.
    case swift(DemangledSymbol)
    /// Linker content, not a symbol (literal pools, `_symbolic`
    /// reflection refs, unwind scaffolding, local labels).
    case contentAtom
    /// Swift mangling prefix, but the name does not parse — corrupt or
    /// truncated.
    case malformed
    /// Everything else: C/C++/ObjC symbols, runtime helpers.
    case nonSwift
}

/// The aggregated census. All fields are independently accumulated so
/// ``violations(against:)`` is a real cross-check, not a tautology.
public struct CensusTally: Sendable {
    /// Classification totals over the live rows.
    public var swift: CensusWeight
    public var nonSwift: CensusWeight
    public var malformed: CensusWeight
    public var contentAtoms: CensusWeight
    /// Non-Swift rows whose name embeds a validated mangling
    /// (`_OBJC_CLASS_$__Tt…` records and friends) — informational, a
    /// subset of `nonSwift`, so it joins no tiling sum.
    public var embeddedMangling: CensusWeight

    /// Swift rows by curated kind (payload kinds as `thunk.curry`,
    /// `accessor.getter`, `metadata.typeMetadata`).
    public var kinds: [String: CensusWeight]
    /// Swift rows by module; the module-less bucket is explicit
    /// (``noModuleKey``).
    public var modules: [String: CensusWeight]
    /// Specialized Swift rows by their generic origin.
    public var specializations: [String: CensusWeight]
    /// Swift rows by identity key — the logical-duplication view; the
    /// report filters to keys with more than one copy.
    public var identities: [String: CensusWeight]
    /// All specialized rows — independently accumulated; must equal the
    /// specialization table plus `unattributedSpecializations`.
    public var specialized: CensusWeight
    /// Specialized rows whose origin the mangling does not recover
    /// (degenerate trees); counted so the specialization table's total
    /// still tiles.
    public var unattributedSpecializations: CensusWeight
    /// Rows whose demangling carries a linker-plumbing suffix
    /// (``linkerPlumbingSuffixes``) — import glue the linker synthesizes
    /// (`_foo.stub`, `_foo.got`), not code anyone wrote. Informational, a
    /// subset of `swift`, so it joins no tiling sum.
    public var linkerPlumbing: CensusWeight
    /// Rows whose size column is physically implausible (≥ 2^48 bytes) —
    /// hostile or corrupt input. Informational; when present, the byte
    /// totals saturate rather than trap, and the report says so.
    public var implausibleSizes: CensusWeight
    /// The headline split: compiler-generated machinery.
    public var machinery: CensusWeight
    /// The headline split: everything else (human-written entry points,
    /// declarations, types).
    public var human: CensusWeight

    public init() {
        swift = CensusWeight()
        nonSwift = CensusWeight()
        malformed = CensusWeight()
        contentAtoms = CensusWeight()
        embeddedMangling = CensusWeight()
        kinds = [:]
        modules = [:]
        specializations = [:]
        identities = [:]
        specialized = CensusWeight()
        unattributedSpecializations = CensusWeight()
        linkerPlumbing = CensusWeight()
        implausibleSizes = CensusWeight()
        machinery = CensusWeight()
        human = CensusWeight()
    }

    /// The linker-plumbing suffix vocabulary, grounded in real `ld` output:
    /// `.stub` (branch islands to imports), `.got` (global-offset-table
    /// slots), `.stub_helper` (the pre-chained-fixups lazy-binding helper).
    public static let linkerPlumbingSuffixes: Set<String> = [".stub", ".got", ".stub_helper"]

    /// The implausible-size floor: no real binary carries a 256 TiB atom.
    public static let implausibleSizeFloor: UInt64 = 1 << 48

    /// The explicit module-less bucket's key. Parenthesized so it can
    /// never collide with a real module name (module identifiers cannot
    /// contain `(`).
    public static let noModuleKey = "(no module)"

    // MARK: Building

    /// Classify one row name. Order matters and is deliberate: the
    /// demangler speaks first (so `l_$s…Hr` conformance records resolve
    /// as Swift, not as local-label atoms), the grounded content-atom
    /// vocabulary second, the malformed check (Swift prefix that does not
    /// parse) third; everything else is non-Swift.
    public static func classify(_ name: String, format: CensusFormat) -> CensusClassification {
        if let symbol = DemangledSymbol(name) {
            return .swift(symbol)
        }
        if format == .linkmap || format == .nm {
            // ld's map (and nm over object files) name assembler-local
            // atoms with a leading `l`; the label often wraps a complete
            // real mangling (`l_$s…Hr` / `l_$s…Hc` runtime records).
            if name.hasPrefix("l"), let symbol = DemangledSymbol(String(name.dropFirst())) {
                return .swift(symbol)
            }
        }
        // `isContentAtom` is total over formats and returns false for
        // `.bare` (bare text has no atom vocabulary), so evaluating it for
        // every format is behavior-preserving — a bare row that reaches
        // here is simply never an atom.
        if isContentAtom(name, format: format) {
            return .contentAtom
        }
        if isSwiftMangled(name) {
            return .malformed
        }
        return .nonSwift
    }

    /// The content-atom vocabulary per format: the full grounded ld-map
    /// vocabulary for linkmaps; for nm only the `_symbolic` reflection
    /// refs (the one atom form real Mach-O nm output shows — the short
    /// linkmap words like `anon` could shadow real ELF symbol names).
    static func isContentAtom(_ name: String, format: CensusFormat) -> Bool {
        switch format {
        case .linkmap: CensusInput.isContentAtomName(name)
        case .nm: name.hasPrefix("_symbolic ")
        case .bare: false
        }
    }

    /// Aggregate a staged harvest — the ``Builder`` over its rows.
    public static func tally(_ harvest: CensusHarvest) -> CensusTally {
        var builder = Builder(format: harvest.format)
        for row in harvest.rows {
            builder.add(name: row.name, sizeBytes: row.size)
        }
        return builder.finish()
    }

    /// The incremental aggregator — one row at a time, so the fused census
    /// pipeline (``CensusInput/harvestAndTally(_:format:reason:)``) can
    /// classify rows as they parse with no staging array between parse and
    /// tally. ``tally(_:)`` runs the identical body over a staged
    /// harvest's rows — one classification implementation.
    public struct Builder {
        var tally = CensusTally()
        let format: CensusFormat
        let scanner = MangledNameScanner()

        public init(format: CensusFormat) {
            self.format = format
        }

        /// Classify and accumulate one live row.
        public mutating func add(name: String, sizeBytes: UInt64?) {
            let bytes = sizeBytes ?? 0
            if bytes >= CensusTally.implausibleSizeFloor {
                tally.implausibleSizes.add(bytes: bytes)
            }
            switch CensusTally.classify(name, format: format) {
            case let .swift(symbol):
                tally.swift.add(bytes: bytes)
                tally.accumulateSwift(symbol, bytes: bytes)
            case .contentAtom:
                tally.contentAtoms.add(bytes: bytes)
            case .malformed:
                tally.malformed.add(bytes: bytes)
            case .nonSwift:
                tally.nonSwift.add(bytes: bytes)
                if !scanner.matches(in: name).isEmpty {
                    tally.embeddedMangling.add(bytes: bytes)
                }
            }
        }

        public func finish() -> CensusTally {
            tally
        }
    }

    /// One Swift row into every table. Fields are read once into locals —
    /// `DemangledSymbol` computes on access, and this is the hot loop.
    mutating func accumulateSwift(_ symbol: DemangledSymbol, bytes: UInt64) {
        let kind = symbol.kind
        kinds[Self.kindDisplayName(kind), default: CensusWeight()].add(bytes: bytes)
        modules[symbol.module ?? Self.noModuleKey, default: CensusWeight()].add(bytes: bytes)
        if symbol.isSpecialized {
            specialized.add(bytes: bytes)
            if let origin = symbol.genericOrigin {
                specializations[origin, default: CensusWeight()].add(bytes: bytes)
            } else {
                unattributedSpecializations.add(bytes: bytes)
            }
        }
        // The identity table groups PHYSICAL atoms: a dot-suffixed row
        // (`_foo.stub`, `_foo.got`) is a different atom than its stem even
        // though the demangler folds them to one logical identity — keying
        // by identity plus suffix keeps the duplication table meaning
        // duplicated code, never import plumbing.
        let identityRow: String = if let suffix = symbol.suffix {
            symbol.identityKey.rawValue + suffix
        } else {
            symbol.identityKey.rawValue
        }
        identities[identityRow, default: CensusWeight()].add(bytes: bytes)
        if let suffix = symbol.suffix, Self.linkerPlumbingSuffixes.contains(suffix) {
            linkerPlumbing.add(bytes: bytes)
        }
        if Self.isMachinery(symbol) {
            machinery.add(bytes: bytes)
        } else {
            human.add(bytes: bytes)
        }
    }

    /// The machinery side of the headline split — exactly the library's
    /// ``DemangledSymbol/isCompilerGenerated``, so a library consumer
    /// reproduces the census numbers from the same single predicate.
    public static func isMachinery(_ symbol: DemangledSymbol) -> Bool {
        symbol.isCompilerGenerated
    }

    /// The table key for a kind — the library's qualified spelling
    /// (``DemangledSymbol/Kind/description``: `accessor.getter`,
    /// `thunk.curry`, `metadata.conformance`).
    public static func kindDisplayName(_ kind: DemangledSymbol.Kind) -> String {
        kind.description
    }

    // MARK: Merging

    /// Fold `other` into this tally — the associative, commutative combine
    /// behind parallel census: two tallies built from disjoint row shards
    /// merge into exactly the tally of their union (every cell adds, every
    /// table merges per key). Because both the classification cells and the
    /// per-key tables accumulate linearly, the merged tally satisfies every
    /// ``violations(against:)`` invariant whenever the summed harvest does —
    /// so a sharded run is byte-identical to the single-threaded one.
    public func merged(with other: CensusTally) -> CensusTally {
        var result = self
        result.swift.combine(other.swift)
        result.nonSwift.combine(other.nonSwift)
        result.malformed.combine(other.malformed)
        result.contentAtoms.combine(other.contentAtoms)
        result.embeddedMangling.combine(other.embeddedMangling)
        result.specialized.combine(other.specialized)
        result.unattributedSpecializations.combine(other.unattributedSpecializations)
        result.linkerPlumbing.combine(other.linkerPlumbing)
        result.implausibleSizes.combine(other.implausibleSizes)
        result.machinery.combine(other.machinery)
        result.human.combine(other.human)
        Self.mergeTable(&result.kinds, other.kinds)
        Self.mergeTable(&result.modules, other.modules)
        Self.mergeTable(&result.specializations, other.specializations)
        Self.mergeTable(&result.identities, other.identities)
        return result
    }

    /// Per-key `CensusWeight` merge of one population table.
    private static func mergeTable(_ into: inout [String: CensusWeight], _ from: [String: CensusWeight]) {
        for (key, weight) in from {
            into[key, default: CensusWeight()].combine(weight)
        }
    }

    // MARK: The books

    /// Every internal tiling invariant, checked against the harvest the
    /// tally was built from. Empty means the books balance; anything here
    /// is reported and fails the run — never silently normalized away.
    ///
    /// The checks are real because both sides accumulate independently:
    /// the harvest sums rows and bytes at parse time, the tally sums per
    /// classification bucket, and each table sums per Swift row.
    public func violations(against harvest: CensusHarvest) -> [String] {
        var problems: [String] = []
        func check(_ condition: Bool, _ message: @autoclosure () -> String) {
            if !condition { problems.append(message()) }
        }

        let classifiedCount = swift.count + nonSwift.count + malformed.count + contentAtoms.count
        check(classifiedCount == harvest.rowCount,
              "classification does not tile: \(classifiedCount) classified != \(harvest.rowCount) rows")
        let classifiedBytes = [swift.bytes, nonSwift.bytes, malformed.bytes, contentAtoms.bytes]
            .reduce(UInt64(0), CensusInput.saturatingAdd)
        check(classifiedBytes == harvest.rowBytes,
              "byte tiling broken: \(classifiedBytes) classified != \(harvest.rowBytes) harvested")

        let kindSum = sum(kinds)
        check(kindSum.count == swift.count, "kind table count does not tile to the swift total")
        check(kindSum.bytes == swift.bytes, "kind table bytes do not tile to the swift total")
        let moduleSum = sum(modules)
        check(moduleSum.count == swift.count, "module table count does not tile to the swift total")
        check(moduleSum.bytes == swift.bytes, "module table bytes do not tile to the swift total")
        let identitySum = sum(identities)
        check(identitySum.count == swift.count, "identity table count does not tile to the swift total")
        check(identitySum.bytes == swift.bytes, "identity table bytes do not tile to the swift total")
        check(machinery.count + human.count == swift.count,
              "machinery/human split count does not tile to the swift total")
        check(CensusInput.saturatingAdd(machinery.bytes, human.bytes) == swift.bytes,
              "machinery/human split bytes do not tile to the swift total")
        let specializationSum = sum(specializations)
        check(specializationSum.count + unattributedSpecializations.count == specialized.count,
              "specialization table count does not tile to the specialized total")
        check(CensusInput.saturatingAdd(specializationSum.bytes, unattributedSpecializations.bytes) == specialized.bytes,
              "specialization table bytes do not tile to the specialized total")
        check(embeddedMangling.count <= nonSwift.count,
              "embedded-mangling count exceeds the non-swift rows it is a subset of")
        check(linkerPlumbing.count <= swift.count,
              "linker-plumbing count exceeds the swift rows it is a subset of")

        if harvest.format != .bare {
            let accounted = harvest.structureLines + harvest.unparseableLines
                + harvest.rowCount + harvest.deadRowCount
            check(accounted == harvest.lines,
                  "line ledger does not tile: \(accounted) accounted != \(harvest.lines) lines")
        }
        return problems
    }

    /// Column sum of a table.
    func sum(_ table: [String: CensusWeight]) -> CensusWeight {
        var total = CensusWeight()
        for cell in table.values {
            total.count += cell.count
            total.bytes = CensusInput.saturatingAdd(total.bytes, cell.bytes)
        }
        return total
    }
}
