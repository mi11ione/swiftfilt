// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// Hand-rolled NDJSON emission: a third-party encoder is out (zero
// dependencies, no Foundation) and key order must be byte-stable — the
// schema documents a fixed field order and the goldens lock it.

import SwiftFilt

/// Deterministic JSON fragments for the `--json` NDJSON stream.
///
/// **Schema, version 1 (add-only).** One object per demangled symbol, one
/// per line, fields in this fixed order; optional fields are *omitted*
/// (never `null`) when absent, so their presence is itself the signal:
///
/// - `schemaVersion` (int): always `1`. New fields may be added without a
///   version bump; existing fields never change meaning or type.
/// - `mangled` (string): the mangled name, byte-for-byte as matched.
/// - `demangled` (string): the rendering in the selected style. Non-empty
///   for the default `full` style (that rendering is the validation
///   gate); may be empty for a degenerate tree in another style — the
///   text filter leaves such matches unrewritten, and the record says so
///   by carrying the empty string.
/// - `style` (string): which preset `demangled` is rendered in —
///   `full`, `simplified`, `qualified`, or `unqualified`.
/// - `module` (string, optional): the defining module, when the tree
///   carries one statically.
/// - `path` (array of strings): the declaration-name path from the module
///   to the symbol's own name (no module, no signatures); `[]` when the
///   tree carries no static names.
/// - `kind` (string): the curated classification — the
///   ``DemangledSymbol/Kind`` case name verbatim (`function`,
///   `initializer`, `deinitializer`, `accessor`, `variable`,
///   `subscriptDeclaration`, `closure`, `variableInitializer`,
///   `defaultArgument`, `type`, `enumCase`, `protocolDeclaration`,
///   `protocolWitness`, `thunk`, `outlined`, `macro`, `metadata`,
///   `other`). Kinds the library adds later appear as soon as the CLI
///   learns them (the mapping is exhaustive, so an engine addition is a
///   compile error here, never a silent `other`).
/// - `accessor` (string, only when `kind` is `accessor`): the
///   ``DemangledSymbol/AccessorKind`` case name (`getter`, `setter`, …).
/// - `thunk` (string, only when `kind` is `thunk`): the
///   ``DemangledSymbol/ThunkKind`` case name (`reabstraction`, `curry`, …).
/// - `metadata` (string, only when `kind` is `metadata`): the
///   ``DemangledSymbol/MetadataKind`` case name (`typeMetadata`, …).
/// - `isStatic` (bool): whether the entity is `static` (or a `class`
///   member, which mangles identically).
/// - `isThunk` (bool): ``DemangledSymbol/isThunk`` — compiler-generated
///   forwarding artifacts, broader than `kind == thunk` (it also covers
///   witnesses and bridging/back-deployment markers).
/// - `isSpecialized` (bool): whether the symbol is a compiler-generated
///   specialization of a generic origin.
/// - `genericOrigin` (string, optional): for a specialization, the `full`
///   rendering of its generic origin.
/// - `identityKey` (string): the crash-grouping key
///   (``DemangledSymbol/identityKey``) — canonical and deterministic
///   within one SwiftFilt version, never empty.
/// - `line` (int, filter mode only): 1-based line number of the match in
///   the input stream (the final unterminated line counts).
/// - `byteOffset` (int, filter mode only): 0-based byte offset of the
///   mangled name's first byte within that line's bytes. `mangled` is
///   pure ASCII, so the match spans
///   `[byteOffset, byteOffset + mangled.count)`.
///
/// Symbol-args mode emits the same object without `line`/`byteOffset`
/// (arguments are argv, not stream positions), one record per argument
/// that demangles, in argument order; an argument that does not demangle
/// emits nothing by default (the stream is exactly the demangled symbols —
/// echoing junk is the text mode's job), or, under `--include-declines`, a
/// `kind:"decline"` record (``declineLine(_:slim:)``) so a batch reports
/// which arguments failed and why. The input line text itself is never
/// embedded, which is what keeps the NDJSON valid UTF-8 even when the
/// scanned stream is not.
///
/// **Why there is no `truncated`/`degenerate` boolean.** Both signals are
/// already carried more richly: a truncated/corrupt argument declines, its
/// `kind:"decline"` record carrying the full parse diagnosis (`status`,
/// `reason`, `stoppedAtByteOffset`); a symbol that parses but renders empty
/// outside `full` shows it by carrying `"demangled":""`. The two together
/// subsume such a flag.
///
/// **The `--slim` projection** drops zero-signal fields and nothing else:
/// `schemaVersion` (constant) and `style` (fixed per invocation) always;
/// `demangled` and `path` when empty; `isStatic`/`isThunk`/`isSpecialized`
/// when false (presence means true). Every kept field carries the same
/// value in the same relative order as the full record.
public enum JSONText {
    /// The `schemaVersion` value emitted on every full-projection line.
    public static let schemaVersion = 1

    /// JSON string literal with the mandatory escapes (quote, backslash,
    /// control characters; the two-character forms where JSON names them).
    public static func string(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let s where s.value < 0x20:
                let hex = String(s.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// JSON array of strings.
    public static func array(_ values: [String]) -> String {
        "[" + values.map(string).joined(separator: ",") + "]"
    }

    /// Filter-mode provenance: where a match sits in the scanned stream.
    @frozen
    public struct Provenance: Sendable, Hashable {
        /// 1-based input line number.
        public var line: Int
        /// 0-based byte offset of the mangled name within the line.
        public var byteOffset: Int

        @inlinable
        public init(line: Int, byteOffset: Int) {
            self.line = line
            self.byteOffset = byteOffset
        }
    }

    /// One NDJSON record for `symbol` in the schema's fixed field order.
    /// `slim` selects the compact projection documented on ``JSONText``.
    public static func symbolLine(
        _ symbol: DemangledSymbol,
        style: DemangleStyle,
        slim: Bool,
        provenance: Provenance? = nil,
    ) -> String {
        var fields: [String] = []
        if !slim {
            fields.append("\"schemaVersion\":\(schemaVersion)")
        }
        fields.append("\"mangled\":\(string(symbol.mangledName))")
        let demangled = symbol.rendered(style)
        if !slim || !demangled.isEmpty {
            fields.append("\"demangled\":\(string(demangled))")
        }
        if !slim {
            fields.append("\"style\":\(string(styleName(style)))")
        }
        if let module = symbol.module {
            fields.append("\"module\":\(string(module))")
        }
        let path = symbol.path
        if !slim || !path.isEmpty {
            fields.append("\"path\":\(array(path))")
        }
        let kind = symbol.kind
        fields.append("\"kind\":\(string(kindName(kind)))")
        switch kind {
        case let .accessor(accessor):
            fields.append("\"accessor\":\(string(accessorName(accessor)))")
        case let .thunk(thunk):
            fields.append("\"thunk\":\(string(thunkName(thunk)))")
        case let .metadata(metadata):
            fields.append("\"metadata\":\(string(metadataName(metadata)))")
        default:
            break
        }
        appendFlag("isStatic", symbol.isStatic, slim: slim, to: &fields)
        appendFlag("isThunk", symbol.isThunk, slim: slim, to: &fields)
        appendFlag("isSpecialized", symbol.isSpecialized, slim: slim, to: &fields)
        if let origin = symbol.genericOrigin {
            fields.append("\"genericOrigin\":\(string(origin))")
        }
        fields.append("\"identityKey\":\(string(symbol.identityKey.rawValue))")
        if let provenance {
            fields.append("\"line\":\(provenance.line)")
            fields.append("\"byteOffset\":\(provenance.byteOffset)")
        }
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// A boolean field: full emits it always, slim only when true
    /// (presence is the witness; false is the silent default).
    private static func appendFlag(_ name: String, _ value: Bool, slim: Bool, to fields: inout [String]) {
        if !slim || value {
            fields.append("\"\(name)\":\(value)")
        }
    }

    /// Stable style names (the ``DemangleStyle`` case names).
    public static func styleName(_ style: DemangleStyle) -> String {
        switch style {
        case .full: "full"
        case .simplified: "simplified"
        case .qualified: "qualified"
        case .unqualified: "unqualified"
        }
    }

    /// Stable kind names (the ``DemangledSymbol/Kind`` case names). The
    /// switch is exhaustive on purpose: a kind the library grows is a
    /// compile error here, so the schema learns it deliberately rather
    /// than mislabeling it.
    public static func kindName(_ kind: DemangledSymbol.Kind) -> String {
        kind.name
    }

    /// Stable accessor names (the ``DemangledSymbol/AccessorKind`` case names).
    public static func accessorName(_ accessor: DemangledSymbol.AccessorKind) -> String {
        accessor.name
    }

    /// Stable thunk names (the ``DemangledSymbol/ThunkKind`` case names).
    public static func thunkName(_ thunk: DemangledSymbol.ThunkKind) -> String {
        thunk.name
    }

    /// Stable metadata names (the ``DemangledSymbol/MetadataKind`` case names).
    public static func metadataName(_ metadata: DemangledSymbol.MetadataKind) -> String {
        metadata.name
    }

    // MARK: Explain objects

    /// One `explain` NDJSON object — the structured story `swiftfilt
    /// explain --json` emits per argument, under the same schemaVersion 1,
    /// add-only, fixed-key-order discipline as the symbol records.
    ///
    /// Common fields (fixed order): `schemaVersion` (1), `kind`
    /// (`"explain"`), `mangled` (the input), `status`
    /// (`"demangled"` · `"malformed"` · `"notSwiftMangled"`), and `era`
    /// (`"stableABI"` · `"embedded"` · `"swift4"` · `"legacy"` ·
    /// `"macro"`) when a Swift prefix was recognized.
    ///
    /// - **`demangled`**: `+ demangled` (the ``DemangleStyle/full``
    ///   rendering), `symbolKind` (the ``DemangledSymbol/Kind`` name),
    ///   `module` (when statically carried), `path`, `identityKey`.
    /// - **`malformed`**: `+ stoppedAtByteOffset`, `reason`
    ///   (`"emptyBody"` · `"truncatedIdentifier"` · `"incompleteInput"` ·
    ///   `"unexpectedByte"` · `"unparseable"`); a `truncatedIdentifier` adds
    ///   `declaredLength` and `availableBytes`, an `unexpectedByte` adds
    ///   `byte` (0–255); `embeddedSymbols` lists any complete names found
    ///   inside, when non-empty. `"unparseable"` (the legacy `_T` grammar,
    ///   which exposes no cursor) carries a `stoppedAtByteOffset` of `0`
    ///   that is not meaningful.
    /// - **`notSwiftMangled`**: `+ foreign` (`"cxxItanium"` · `"rust"`)
    ///   when the bytes resemble a known foreign scheme.
    ///
    /// **`--slim`** drops `schemaVersion` only; every other field is
    /// byte-identical to the full record's.
    ///
    /// `kind` tags the record: `"explain"` for the `explain` verb, and
    /// `"decline"` when the same diagnosis is emitted for a declined symbol
    /// argument on the main `--json` stream (``declineLine(_:slim:)``). Only
    /// the `malformed`/`notSwiftMangled` outcomes reach the decline path (a
    /// symbol that demangled is a `symbol` record, never a decline).
    public static func explainLine(_ explanation: SymbolExplanation, slim: Bool, kind: String = "explain") -> String {
        var fields: [String] = []
        if !slim {
            fields.append("\"schemaVersion\":\(schemaVersion)")
        }
        fields.append("\"kind\":\(string(kind))")
        fields.append("\"mangled\":\(string(explanation.mangledName))")
        switch explanation.outcome {
        case let .demangled(symbol):
            fields.append("\"status\":\"demangled\"")
            appendEra(explanation.era, to: &fields)
            fields.append("\"demangled\":\(string(symbol.rendered(.full)))")
            fields.append("\"symbolKind\":\(string(symbol.kind.name))")
            if let module = symbol.module {
                fields.append("\"module\":\(string(module))")
            }
            fields.append("\"path\":\(array(symbol.path))")
            fields.append("\"identityKey\":\(string(symbol.identityKey.rawValue))")
        case let .malformed(malformed):
            fields.append("\"status\":\"malformed\"")
            appendEra(explanation.era, to: &fields)
            fields.append("\"stoppedAtByteOffset\":\(malformed.stoppedAtByteOffset)")
            switch malformed.reason {
            case .emptyBody:
                fields.append("\"reason\":\"emptyBody\"")
            case let .truncatedIdentifier(declaredLength, availableBytes):
                fields.append("\"reason\":\"truncatedIdentifier\"")
                fields.append("\"declaredLength\":\(declaredLength)")
                fields.append("\"availableBytes\":\(availableBytes)")
            case .incompleteInput:
                fields.append("\"reason\":\"incompleteInput\"")
            case let .unexpectedByte(byte):
                fields.append("\"reason\":\"unexpectedByte\"")
                fields.append("\"byte\":\(byte)")
            case .unparseable:
                fields.append("\"reason\":\"unparseable\"")
            }
            if !malformed.embeddedSymbols.isEmpty {
                fields.append("\"embeddedSymbols\":\(array(malformed.embeddedSymbols))")
            }
        case let .notSwiftMangled(foreign):
            fields.append("\"status\":\"notSwiftMangled\"")
            if let foreign {
                fields.append("\"foreign\":\(string(foreignName(foreign)))")
            }
        }
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// The decline record for the main `--json` stream: a `kind:"decline"`
    /// object carrying the same honest diagnosis `explain` gives (era,
    /// status, stop position, reason, any complete embedded symbols) for a
    /// symbol *argument* that does not demangle. Emitted only under
    /// `--include-declines`; the default `--json` stream stays exactly the
    /// demangled symbols. The subject did not demangle (else the CLI emits a
    /// `symbol` record), so the outcome is always `malformed` or
    /// `notSwiftMangled` — the truncated/corrupt diagnosis a boolean flag
    /// could not carry (this is why a separate truncated/degenerate boolean
    /// is unnecessary: the decline record is strictly richer).
    public static func declineLine(mangled: String, slim: Bool) -> String {
        explainLine(SymbolExplanation(parsing: mangled), slim: slim, kind: "decline")
    }

    /// The optional `era` field.
    private static func appendEra(_ era: ManglingEra?, to fields: inout [String]) {
        if let era {
            fields.append("\"era\":\(string(era.name))")
        }
    }

    /// Stable foreign-scheme names (the ``SymbolExplanation/ForeignMangling`` cases).
    public static func foreignName(_ foreign: SymbolExplanation.ForeignMangling) -> String {
        switch foreign {
        case .cxxItanium: "cxxItanium"
        case .rust: "rust"
        }
    }

    // MARK: Census objects

    /// The `census --json` stream, under the same schema version and
    /// add-only discipline as the symbol records: one **summary** object
    /// (`kind` is `census`), then one object per table row (`kind` is
    /// `censusRow`), in the exact order and ranking of the human report's
    /// tables — but always complete (`--top` shapes the human report
    /// only; machine consumers filter themselves).
    ///
    /// **Summary object**, fields in this fixed order (optional fields
    /// are omitted, never `null`; `…Bytes` twins appear only when
    /// `weight` is `bytes`):
    ///
    /// - `schemaVersion` (int): always `1`.
    /// - `kind` (string): `census`.
    /// - `format` (string): `bare`, `nm`, or `linkmap`.
    /// - `weight` (string): `bytes` when the input carried sizes,
    ///   `count` otherwise — says which weighting every `…Bytes` field
    ///   and the ranking used.
    /// - `detection` (string): the format-detection reasoning.
    /// - `path`, `arch` (string, linkmap): the map's `# Path:`/`# Arch:`
    ///   headers, when present.
    /// - `objectFiles` (int, linkmap): entries in the object-file table.
    /// - `lines` (int): input lines.
    /// - `structureLines`, `unparseableLines` (int, nm/linkmap): the
    ///   line ledger — scaffolding, and lines that failed the row shape
    ///   (counted, never dropped).
    /// - `rows` (int) and `rowBytes`: the live row population.
    /// - `swift`/`swiftBytes`, and (nm/linkmap) `nonSwift`/…,
    ///   `malformed`/…, `contentAtoms`/…: the row classification; the
    ///   four counts (and byte twins) tile exactly to `rows`/`rowBytes`.
    /// - `embeddedMangling`/… (nm/linkmap): non-Swift rows whose name
    ///   embeds a validated mangling (informational subset of
    ///   `nonSwift`).
    /// - `linkerPlumbing`/… (nm/linkmap): Swift rows carrying a
    ///   linker-plumbing suffix (`.stub`/`.got`/`.stub_helper`) —
    ///   import glue, kept out of the duplication table (informational
    ///   subset of `swift`).
    /// - `implausibleSizes`/… (nm/linkmap): rows whose size column is
    ///   ≥ 2^48 bytes — hostile/corrupt input; byte totals saturate and
    ///   the human report warns.
    /// - `deadStripped`/`deadStrippedBytes` (linkmap): dead-stripped
    ///   rows — never part of `rows`.
    /// - `undefinedRows` (int, nm): `U`/`u` rows (references, not
    ///   definitions).
    /// - `rowsWithoutSize` (int, nm, sized dumps): rows weighed as 0
    ///   bytes because they carried no size.
    /// - `unknownOrdinalRows` (int, linkmap): rows citing an ordinal the
    ///   object-file table never declared.
    /// - `machinery`/…, `human`/…: the compiler-generated split (tiles
    ///   to `swift`).
    /// - `specialized`/…, `unattributedSpecializations`/…: specialized
    ///   rows in total, and those whose origin was not recoverable.
    ///
    /// **Row objects**: `schemaVersion`, `kind` (`censusRow`), `table`
    /// (`kinds`, `modules`, `specializations`, or `duplicates`), `name`
    /// (the kind name / module / generic origin / identity key), `count`
    /// (rows; copies for `specializations` and `duplicates`), and
    /// `bytes` when `weight` is `bytes`. `duplicates` carries only
    /// identity keys with more than one copy.
    ///
    /// **`--slim`** drops `schemaVersion` (constant) and the summary's
    /// `detection` prose; every kept field is byte-identical to the full
    /// record's. Counts are never dropped at zero — a zero is exactly
    /// what a CI gate reads.
    public static func censusLines(harvest: CensusHarvest, tally: CensusTally, slim: Bool) -> [String] {
        var lines = [censusSummaryLine(harvest: harvest, tally: tally, slim: slim)]
        let sized = harvest.sizesPresent
        appendCensusTable("kinds", cells: CensusReport.rankedCells(tally.kinds, sized: sized),
                          sized: sized, slim: slim, to: &lines)
        appendCensusTable("modules", cells: CensusReport.rankedCells(tally.modules, sized: sized),
                          sized: sized, slim: slim, to: &lines)
        appendCensusTable("specializations", cells: CensusReport.rankedCells(tally.specializations, sized: sized),
                          sized: sized, slim: slim, to: &lines)
        appendCensusTable("duplicates", cells: CensusReport.duplicateCells(tally.identities),
                          sized: sized, slim: slim, to: &lines)
        return lines
    }

    /// The census summary object (see ``censusLines(harvest:tally:slim:)``
    /// for the field contract).
    public static func censusSummaryLine(harvest: CensusHarvest, tally: CensusTally, slim: Bool) -> String {
        let sized = harvest.sizesPresent
        var fields: [String] = []
        if !slim {
            fields.append("\"schemaVersion\":\(schemaVersion)")
        }
        fields.append("\"kind\":\"census\"")
        fields.append("\"format\":\(string(harvest.format.rawValue))")
        fields.append("\"weight\":\(string(sized ? "bytes" : "count"))")
        if !slim {
            fields.append("\"detection\":\(string(harvest.detectionReason))")
        }
        if harvest.format == .linkmap {
            if let path = harvest.path {
                fields.append("\"path\":\(string(path))")
            }
            if let arch = harvest.arch {
                fields.append("\"arch\":\(string(arch))")
            }
            fields.append("\"objectFiles\":\(harvest.objectFiles.count)")
        }
        fields.append("\"lines\":\(harvest.lines)")
        if harvest.format != .bare {
            fields.append("\"structureLines\":\(harvest.structureLines)")
            fields.append("\"unparseableLines\":\(harvest.unparseableLines)")
        }
        appendCensusWeight("rows", CensusWeight(count: harvest.rowCount, bytes: harvest.rowBytes),
                           bytesKey: "rowBytes", sized: sized, to: &fields)
        appendCensusWeight("swift", tally.swift, sized: sized, to: &fields)
        if harvest.format != .bare {
            appendCensusWeight("nonSwift", tally.nonSwift, sized: sized, to: &fields)
            appendCensusWeight("malformed", tally.malformed, sized: sized, to: &fields)
            appendCensusWeight("contentAtoms", tally.contentAtoms, sized: sized, to: &fields)
            appendCensusWeight("embeddedMangling", tally.embeddedMangling, sized: sized, to: &fields)
            appendCensusWeight("linkerPlumbing", tally.linkerPlumbing, sized: sized, to: &fields)
            appendCensusWeight("implausibleSizes", tally.implausibleSizes, sized: sized, to: &fields)
        }
        if harvest.format == .linkmap {
            appendCensusWeight("deadStripped", CensusWeight(count: harvest.deadRowCount, bytes: harvest.deadRowBytes),
                               sized: sized, to: &fields)
        }
        if harvest.format == .nm {
            fields.append("\"undefinedRows\":\(harvest.undefinedRows)")
            if sized {
                fields.append("\"rowsWithoutSize\":\(harvest.rowsWithoutSize)")
            }
        }
        if harvest.format == .linkmap {
            fields.append("\"unknownOrdinalRows\":\(harvest.unknownOrdinalRows)")
        }
        appendCensusWeight("machinery", tally.machinery, sized: sized, to: &fields)
        appendCensusWeight("human", tally.human, sized: sized, to: &fields)
        appendCensusWeight("specialized", tally.specialized, sized: sized, to: &fields)
        appendCensusWeight("unattributedSpecializations", tally.unattributedSpecializations,
                           sized: sized, to: &fields)
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// One census table-row object.
    public static func censusRowLine(table: String, name: String, weight: CensusWeight, sized: Bool, slim: Bool) -> String {
        var fields: [String] = []
        if !slim {
            fields.append("\"schemaVersion\":\(schemaVersion)")
        }
        fields.append("\"kind\":\"censusRow\"")
        fields.append("\"table\":\(string(table))")
        fields.append("\"name\":\(string(name))")
        fields.append("\"count\":\(weight.count)")
        if sized {
            fields.append("\"bytes\":\(weight.bytes)")
        }
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// A count field plus its `…Bytes` twin when the input is sized.
    private static func appendCensusWeight(
        _ key: String, _ weight: CensusWeight,
        bytesKey: String? = nil, sized: Bool, to fields: inout [String],
    ) {
        fields.append("\"\(key)\":\(weight.count)")
        if sized {
            fields.append("\"\(bytesKey ?? key + "Bytes")\":\(weight.bytes)")
        }
    }

    /// All rows of one table, in ranked order.
    private static func appendCensusTable(
        _ table: String,
        cells: [(name: String, weight: CensusWeight)],
        sized: Bool, slim: Bool, to lines: inout [String],
    ) {
        for cell in cells {
            lines.append(censusRowLine(table: table, name: cell.name, weight: cell.weight, sized: sized, slim: slim))
        }
    }
}
