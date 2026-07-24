// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// The census's human face: tight aligned tables over the tally, in the
// weight the input honestly supports — bytes when the input carried
// sizes, counts otherwise, always labeled as which. Numbers lead each
// row (`uniq -c` reading order) because census names — identity keys,
// generic origins — run long.

import SwiftFilt

/// Renders the human `census` report.
public enum CensusReport {
    /// One input-ledger row: a label, its weight, whether the bytes
    /// column applies to it (line tallies have no bytes), and a trailing
    /// note.
    struct LedgerRow {
        var label: String
        var weight: CensusWeight
        var showBytes: Bool
        var note = ""
    }

    /// The whole report. `top` caps the module / specialization /
    /// duplication tables (the kind table is a bounded taxonomy and
    /// always prints whole); what a cap hides is aggregated into an
    /// explicit `(+ N more …)` residual row, so every table still sums
    /// to its population. `--json` output is never capped.
    public static func render(
        harvest: CensusHarvest,
        tally: CensusTally,
        top: Int,
        palette: Palette,
    ) -> String {
        let sized = harvest.sizesPresent
        var sections: [[String]] = []
        sections.append(headerSection(harvest: harvest, sized: sized, palette: palette))
        sections.append(inputSection(harvest: harvest, tally: tally, sized: sized, palette: palette))
        sections.append(machinerySection(tally: tally, sized: sized, palette: palette))
        sections.append(tableSection(
            title: "swift by kind", nameHeader: "kind",
            cells: rankedCells(tally.kinds, sized: sized),
            sized: sized, top: nil, residualNoun: "kinds", palette: palette,
        ))
        sections.append(tableSection(
            title: "swift by module", nameHeader: "module",
            cells: rankedCells(tally.modules, sized: sized),
            sized: sized, top: top, residualNoun: "modules", palette: palette,
        ))
        sections.append(specializationSection(tally: tally, sized: sized, top: top, palette: palette))
        sections.append(tableSection(
            title: "duplicated logical functions", nameHeader: "identity",
            cells: duplicateCells(tally.identities),
            sized: sized, top: top, residualNoun: "duplicated functions",
            countHeader: "copies", palette: palette,
        ))
        return sections.map { $0.joined(separator: "\n") }.joined(separator: "\n\n") + "\n"
    }

    /// The title block: format, weighting, linkmap provenance, and the
    /// detection reasoning (why this input parsed as what it did).
    static func headerSection(harvest: CensusHarvest, sized: Bool, palette: Palette) -> [String] {
        var lines = [palette.heading("census — \(formatTitle(harvest.format)), \(sized ? "size" : "count")-weighted")]
        if harvest.format == .linkmap {
            let path = harvest.path ?? "(no # Path: header)"
            let arch = harvest.arch ?? "unknown arch"
            lines.append("  \(path) (\(arch)), \(grouped(harvest.objectFiles.count)) object files")
        }
        lines.append("  detected: \(harvest.detectionReason)")
        return lines
    }

    /// The input ledger: every line and byte of the input, tiled into
    /// named buckets — the report's honesty section.
    static func inputSection(harvest: CensusHarvest, tally: CensusTally, sized: Bool, palette: Palette) -> [String] {
        var rows: [LedgerRow] = [LedgerRow(label: "lines", weight: CensusWeight(count: harvest.lines), showBytes: false)]
        if harvest.format == .bare {
            rows.append(LedgerRow(
                label: "manglings found",
                weight: CensusWeight(count: harvest.rowCount), showBytes: false,
            ))
        } else {
            rows.append(LedgerRow(label: "structure lines", weight: CensusWeight(count: harvest.structureLines), showBytes: false))
            rows.append(LedgerRow(label: "unparseable lines", weight: CensusWeight(count: harvest.unparseableLines), showBytes: false))
            rows.append(LedgerRow(
                label: "rows",
                weight: CensusWeight(count: harvest.rowCount, bytes: harvest.rowBytes), showBytes: true,
            ))
            rows.append(LedgerRow(label: "  swift", weight: tally.swift, showBytes: true))
            rows.append(LedgerRow(label: "  non-swift", weight: tally.nonSwift, showBytes: true))
            rows.append(LedgerRow(label: "  malformed swift-prefix", weight: tally.malformed, showBytes: true))
            rows.append(LedgerRow(label: "  content atoms (skipped)", weight: tally.contentAtoms, showBytes: true))
        }
        if harvest.format == .linkmap {
            rows.append(LedgerRow(
                label: "dead-stripped rows",
                weight: CensusWeight(count: harvest.deadRowCount, bytes: harvest.deadRowBytes), showBytes: true,
                note: "   not in the binary; excluded from every table",
            ))
        }
        var lines = [palette.heading("input")]
        let width = numberColumnWidths(rows.map(\.weight), sized: sized)
        for row in rows {
            lines.append(ledgerLine(row, sized: sized, width: width))
        }
        if tally.embeddedMangling.count > 0 {
            lines.append("  non-swift rows embedding a swift mangling: "
                + weightPhrase(tally.embeddedMangling, sized: sized))
        }
        if harvest.undefinedRows > 0 {
            lines.append("  undefined (U) rows counted above: \(grouped(harvest.undefinedRows)) — references, not definitions")
        }
        if sized, harvest.rowsWithoutSize > 0 {
            lines.append("  rows with no size column: \(grouped(harvest.rowsWithoutSize)) (weighed as 0 bytes)")
        }
        if harvest.unknownOrdinalRows > 0 {
            lines.append("  rows citing an object-file ordinal the map never declared: \(grouped(harvest.unknownOrdinalRows))")
        }
        if tally.linkerPlumbing.count > 0 {
            lines.append("  linker plumbing (.stub/.got import glue) among swift rows: "
                + weightPhrase(tally.linkerPlumbing, sized: sized))
        }
        if tally.implausibleSizes.count > 0 {
            lines.append("  IMPLAUSIBLE row sizes (≥ 2^48 bytes): \(grouped(tally.implausibleSizes.count)) — byte totals saturate; treat them as unreliable")
        }
        return lines
    }

    /// The headline split, with its percentage line and the definition
    /// footnote (the split is only as honest as its stated boundary).
    static func machinerySection(tally: CensusTally, sized: Bool, palette: Palette) -> [String] {
        var lines = [palette.heading("compiler-generated machinery")]
        guard tally.swift.count > 0 else {
            lines.append("  (no swift symbols)")
            return lines
        }
        let share = sized
            ? "\(percent(tally.machinery.bytes, of: tally.swift.bytes)) of swift bytes (\(grouped(tally.machinery.count)) of \(grouped(tally.swift.count)) symbols)"
            : "\(percent(UInt64(tally.machinery.count), of: UInt64(tally.swift.count))) of swift symbols (\(grouped(tally.machinery.count)) of \(grouped(tally.swift.count)))"
        lines.append("  machinery is \(share)")
        let rows = [
            LedgerRow(label: "machinery", weight: tally.machinery, showBytes: true),
            LedgerRow(label: "human-written", weight: tally.human, showBytes: true),
        ]
        let width = numberColumnWidths(rows.map(\.weight), sized: sized)
        for row in rows {
            lines.append(ledgerLine(row, sized: sized, width: width))
        }
        lines.append("  machinery = thunks + witnesses + bridging entry points + outlined code")
        lines.append("              + metadata records + variable/default-argument initializers")
        return lines
    }

    /// The specialization table plus its unattributed residue.
    static func specializationSection(tally: CensusTally, sized: Bool, top: Int, palette: Palette) -> [String] {
        var lines = tableSection(
            title: "specialized generic origins", nameHeader: "generic origin",
            cells: rankedCells(tally.specializations, sized: sized),
            sized: sized, top: top, residualNoun: "origins",
            countHeader: "copies", palette: palette,
        )
        if tally.unattributedSpecializations.count > 0 {
            lines.append("  unattributable specializations (origin not recoverable): "
                + weightPhrase(tally.unattributedSpecializations, sized: sized))
        }
        return lines
    }

    /// One ranked table: header row, `count [bytes] name` rows, an
    /// explicit residual row when `top` capped it, `(none)` when empty.
    static func tableSection(
        title: String,
        nameHeader: String,
        cells: [(name: String, weight: CensusWeight)],
        sized: Bool,
        top: Int?,
        residualNoun: String,
        countHeader: String = "count",
        palette: Palette,
    ) -> [String] {
        var lines: [String] = []
        var shown = cells
        var residual: (name: String, weight: CensusWeight)?
        if let top, cells.count > top {
            shown = Array(cells.prefix(top))
            var rest = CensusWeight()
            for cell in cells.dropFirst(top) {
                rest.count += cell.weight.count
                rest.bytes = CensusInput.saturatingAdd(rest.bytes, cell.weight.bytes)
            }
            residual = ("(+ \(grouped(cells.count - top)) more \(residualNoun))", rest)
            lines.append(palette.heading("\(title) (top \(top) of \(grouped(cells.count)))"))
        } else {
            lines.append(palette.heading(title))
        }
        guard !shown.isEmpty else {
            lines.append("  (none)")
            return lines
        }
        let rows = shown + (residual.map { [$0] } ?? [])
        var width = numberColumnWidths(rows.map(\.weight), sized: sized)
        width.count = max(width.count, countHeader.count)
        if sized { width.bytes = max(width.bytes, "bytes".count) }
        var header = "  " + padLeft(countHeader, to: width.count)
        if sized { header += "  " + padLeft("bytes", to: width.bytes) }
        header += "  " + nameHeader
        lines.append(header)
        for cell in rows {
            var line = "  " + padLeft(grouped(cell.weight.count), to: width.count)
            if sized { line += "  " + padLeft(grouped(cell.weight.bytes), to: width.bytes) }
            line += "  " + cell.name
            lines.append(line)
        }
        return lines
    }

    // MARK: Ranking

    /// Table cells ranked by the input's honest weight: bytes (then
    /// count) when sizes exist, count otherwise; name breaks every tie,
    /// so reruns are byte-identical.
    static func rankedCells(_ table: [String: CensusWeight], sized: Bool) -> [(name: String, weight: CensusWeight)] {
        table.map { (name: $0.key, weight: $0.value) }.sorted { lhs, rhs in
            if sized, lhs.weight.bytes != rhs.weight.bytes { return lhs.weight.bytes > rhs.weight.bytes }
            if lhs.weight.count != rhs.weight.count { return lhs.weight.count > rhs.weight.count }
            return lhs.name < rhs.name
        }
    }

    /// Duplication cells: identity keys with more than one copy, ranked
    /// by copies (duplication is a count phenomenon), then bytes, then
    /// name.
    static func duplicateCells(_ identities: [String: CensusWeight]) -> [(name: String, weight: CensusWeight)] {
        identities.filter { $0.value.count > 1 }
            .map { (name: $0.key, weight: $0.value) }
            .sorted { lhs, rhs in
                if lhs.weight.count != rhs.weight.count { return lhs.weight.count > rhs.weight.count }
                if lhs.weight.bytes != rhs.weight.bytes { return lhs.weight.bytes > rhs.weight.bytes }
                return lhs.name < rhs.name
            }
    }

    // MARK: Formatting

    /// The report title for a format.
    static func formatTitle(_ format: CensusFormat) -> String {
        switch format {
        case .bare: "bare text"
        case .nm: "nm output"
        case .linkmap: "Xcode LinkMap"
        }
    }

    /// A ledger line: label padded, count right-aligned, bytes
    /// right-aligned when the input is sized and the row is a byte row.
    static func ledgerLine(_ row: LedgerRow, sized: Bool, width: (count: Int, bytes: Int)) -> String {
        var line = "  " + padRight(row.label, to: 26) + padLeft(grouped(row.weight.count), to: width.count)
        if sized, row.showBytes {
            line += "  " + padLeft(grouped(row.weight.bytes), to: width.bytes) + " bytes"
        }
        return line + row.note
    }

    /// Column widths that fit every number in the section.
    static func numberColumnWidths(_ weights: [CensusWeight], sized: Bool) -> (count: Int, bytes: Int) {
        var count = 1
        var bytes = 1
        for weight in weights {
            count = max(count, grouped(weight.count).count)
            if sized { bytes = max(bytes, grouped(weight.bytes).count) }
        }
        return (count, bytes)
    }

    /// `N (B bytes)` or plain `N` per the weighting.
    static func weightPhrase(_ weight: CensusWeight, sized: Bool) -> String {
        sized ? "\(grouped(weight.count)) (\(grouped(weight.bytes)) bytes)" : grouped(weight.count)
    }

    /// Deterministic thousands grouping (no locale anywhere).
    static func grouped(_ value: some BinaryInteger) -> String {
        let digits = Array(String(value))
        var out: [Character] = []
        for (offset, digit) in digits.enumerated() {
            if offset > 0, (digits.count - offset) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return String(out)
    }

    /// `part` as a percentage of `total`, one decimal, integer math with
    /// round-half-up (never locale- or FP-formatting-dependent). Both
    /// values are pre-scaled if the multiply would overflow — hostile
    /// inputs can claim exabyte sizes, and the census must not trap.
    static func percent(_ part: UInt64, of total: UInt64) -> String {
        guard total > 0 else { return "0.0%" }
        var part = part
        var total = total
        while part > UInt64.max / 1000 {
            part >>= 10
            total = max(total >> 10, 1)
        }
        let permille = (part * 1000 + total / 2) / total
        return "\(permille / 10).\(permille % 10)%"
    }

    /// Right-pad to a column (one space minimum).
    static func padRight(_ text: String, to width: Int) -> String {
        text + String(repeating: " ", count: max(width - text.count, 1))
    }

    /// Left-pad to a column (right-aligned numbers).
    static func padLeft(_ text: String, to width: Int) -> String {
        String(repeating: " ", count: max(width - text.count, 0)) + text
    }
}
