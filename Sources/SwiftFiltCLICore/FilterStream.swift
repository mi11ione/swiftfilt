// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// The streaming filter: frames chunked input bytes into lines, keeps the
// partial-line buffer bounded, and hands each chunk's completed output
// onward before the next chunk is read — so `tail -f | swiftfilt`
// renders live, memory stays bounded on unbounded pipes, and non-symbol
// bytes (invalid UTF-8 included) pass through byte-identical.

import SwiftFilt

/// Incremental filter-mode processor. Feed raw input chunks through
/// ``consume(_:emit:)`` and close with ``finish(emit:)``; output leaves
/// through `emit` as raw bytes — everything a chunk completes, batched
/// into one call, before the next chunk is read. Never accumulated
/// whole-stream: liveness is per input chunk, syscalls are not per line.
///
/// **Framing.** Lines are `\n`-delimited; the delimiter is preserved on
/// output and a final unterminated line is emitted without one, so a
/// stream with no matches round-trips byte-for-byte. `\r\n` needs no
/// special case: `\r` is not a mangling character, so it can never be
/// swallowed into a match. Rewrite mode scans each chunk's completed
/// lines as ONE region (a candidate can never contain or cross a `\n`,
/// so region output equals per-line output byte for byte — and a region
/// is what the optional ``ParallelRewriter`` spreads across cores);
/// tree/JSON mode frames per line for its line-number provenance.
///
/// **Bounded memory.** Only the current partial line is buffered. When a
/// single line exceeds ``windowCapacity`` (binaries piped through the
/// filter can run megabytes between newlines), the buffered prefix is
/// processed and flushed early, cut at the start of its trailing maximal
/// mangling-character run — the one cut point that provably splits no
/// candidate, so windowed output equals whole-line output. The sole
/// degradation: a single unbroken mangling-character run longer than the
/// window passes through unscanned in its entirety (no real mangled name
/// is remotely that long; deterministic and documented rather than
/// unbounded buffering).
public struct FilterStream {
    /// What each match becomes on output.
    public enum Mode: Sendable, Hashable {
        /// Rewrite matches in place (optionally classify-marked), pass
        /// everything else through.
        case rewrite(classify: Bool)
        /// Replace nothing; print each match's node tree.
        case tree
        /// Replace nothing; print each match's NDJSON record.
        case json(slim: Bool)
    }

    /// The partial-line buffer cap: 4 MiB. Beyond it the buffered prefix
    /// is flushed early (see the type documentation). Steady-state memory
    /// is bounded by this plus one input chunk.
    public static let windowCapacity = 4 << 20

    private let mode: Mode
    private let style: DemangleStyle
    private let palette: Palette
    private let scanner = MangledNameScanner()
    /// One demangle engine for the whole stream: per-call construction (arena
    /// slabs + printer buffer) was the dominant per-call cost, and calls are
    /// independent (each installs its own scan buffer), so reuse across
    /// regions — and across `FilterStream` copies, never used concurrently
    /// (not `Sendable`) — is behavior-neutral.
    private let engine = ArenaDemangleEngine()
    /// The parallel rewrite engine, or `nil` for the always-sequential
    /// stream. Only rewrite mode consults it, and only for regions big
    /// enough to split; output bytes are identical either way (the
    /// parallel-vs-sequential equivalence is pinned by test and golden).
    private let parallel: ParallelRewriter?

    private var buffer: [UInt8] = []
    /// Where the next `\n` search resumes (bytes before it are known
    /// newline-free), so framing stays linear over pathological chunking.
    private var searchStart = 0
    /// 1-based line number of the line currently buffering.
    private var lineNumber = 1
    /// Bytes of the current line already flushed by windowing — the
    /// provenance offset for matches found in later windows of the line.
    private var lineBase = 0
    /// Set while discarding an over-window mangling-character run: the
    /// run's remaining bytes pass through unscanned until it breaks.
    private var discardingOversizedRun = false
    /// The per-consume output accumulator, reused across calls (capacity
    /// kept) so a steady saturated stream allocates no output buffer per
    /// round — large transient buffers were the filter's peak-RSS driver.
    private var emitScratch: [UInt8] = []

    public init(mode: Mode, style: DemangleStyle, palette: Palette, parallel: ParallelRewriter? = nil) {
        self.mode = mode
        self.style = style
        self.palette = palette
        self.parallel = parallel
    }

    /// Feed one input chunk. Everything the chunk completes is handed to
    /// `emit` before this call returns — one batched write per chunk, so
    /// a `tail -f` pipeline stays live (output always precedes the next
    /// read) without a syscall per line at full pipe speed.
    public mutating func consume(_ chunk: [UInt8], emit: ([UInt8]) -> Void) {
        buffer.append(contentsOf: chunk)
        // The output accumulator shuttles out of its stored slot for the
        // drains (struct exclusivity forbids borrowing a stored property
        // inout during a mutating call) — a pure exchange, so its capacity is
        // reused round after round with no per-round allocation.
        var pending: [UInt8] = []
        swap(&pending, &emitScratch)
        pending.removeAll(keepingCapacity: true)
        if case .rewrite = mode {
            drainRewriteRegion(into: &pending)
        } else {
            drainCompleteLines(into: &pending)
        }
        enforceWindow(into: &pending)
        if !pending.isEmpty {
            emit(pending)
        }
        swap(&pending, &emitScratch)
    }

    /// Close the stream: the final unterminated line (if any) is emitted
    /// without a trailing newline.
    public mutating func finish(emit: ([UInt8]) -> Void) {
        guard !buffer.isEmpty else { return }
        let line = buffer
        buffer = []
        searchStart = 0
        var pending: [UInt8] = []
        swap(&pending, &emitScratch)
        pending.removeAll(keepingCapacity: true)
        process(line: line, into: &pending)
        if !pending.isEmpty {
            emit(pending)
        }
        swap(&pending, &emitScratch)
    }

    // MARK: Framing

    private mutating func drainCompleteLines(into pending: inout [UInt8]) {
        var start = 0
        var index = searchStart
        let newline = UInt8(ascii: "\n")
        while index < buffer.count {
            if buffer[index] == newline {
                process(line: Array(buffer[start ..< index]), into: &pending)
                lineNumber += 1
                lineBase = 0
                start = index + 1
            }
            index += 1
        }
        if start > 0 {
            buffer.removeFirst(start)
        }
        searchStart = buffer.count
    }

    /// The rewrite-mode drain: everything up to the buffer's LAST newline
    /// is one region, scanned IN PLACE in a single pass instead of line by
    /// line. Byte-equivalent to the per-line drain — a candidate can never
    /// contain or cross a `\n` (not a mangling character; every prefix
    /// gate rejects it), and rewrite output preserves non-candidate bytes
    /// (newlines included) verbatim — while skipping the per-line slice
    /// copy, the per-line scan setup, AND the per-region byte copy that
    /// dominated dense-log filtering (and its peak RSS). Rewrite mode
    /// reads no line numbers, so none are tracked here; the tree/JSON
    /// modes keep the per-line drain for their provenance.
    private mutating func drainRewriteRegion(into pending: inout [UInt8]) {
        // Find the last newline among the newly buffered bytes (bytes
        // before `searchStart` are known newline-free).
        let newline = UInt8(ascii: "\n")
        var last = -1
        var index = buffer.count - 1
        while index >= searchStart {
            if buffer[index] == newline { last = index; break }
            index -= 1
        }
        guard last >= 0 else {
            searchStart = buffer.count
            return
        }
        var regionStart = 0
        if discardingOversizedRun {
            // The region starts inside a discarded run: bytes up to the
            // run's break pass through raw. The newline at `last` is
            // itself a break, so the search always terminates by there
            // and the flag always clears with this region.
            discardingOversizedRun = false
            while MangledNameScanner.isManglingCharacter(buffer[regionStart]) {
                regionStart += 1
            }
            pending.append(contentsOf: buffer[..<regionStart])
        }
        if case let .rewrite(classify) = mode {
            processRewrite(buffer, in: regionStart ..< last + 1, classify: classify, into: &pending)
        }
        buffer.removeFirst(last + 1)
        searchStart = buffer.count
    }

    /// Keep the partial-line buffer at or under ``windowCapacity`` by
    /// flushing a safely scannable prefix (or continuing a raw discard).
    private mutating func enforceWindow(into pending: inout [UInt8]) {
        while buffer.count > Self.windowCapacity {
            if discardingOversizedRun {
                // Pass run bytes through raw until the run breaks; the
                // break byte itself rejoins normal scanning (the loop
                // re-enters through the normal branch, which always
                // makes progress, so this cannot spin).
                if let breakIndex = buffer.firstIndex(where: { !MangledNameScanner.isManglingCharacter($0) }) {
                    flushRaw(count: breakIndex, into: &pending)
                    discardingOversizedRun = false
                } else {
                    flushRaw(count: buffer.count, into: &pending)
                    return
                }
                continue
            }
            // Cut at the start of the trailing maximal mangling-character
            // run — no candidate spans that point. A `@` just before the
            // run could begin an `@__swiftmacro_` candidate, so it joins
            // the run.
            var cut = buffer.count
            while cut > 0, MangledNameScanner.isManglingCharacter(buffer[cut - 1]) {
                cut -= 1
            }
            if cut > 0, buffer[cut - 1] == UInt8(ascii: "@") {
                cut -= 1
            }
            guard cut > 0 else {
                // The whole window is one unbroken run: the documented
                // degradation — it passes through unscanned, as does the
                // rest of the run as it streams in.
                flushRaw(count: buffer.count, into: &pending)
                discardingOversizedRun = true
                return
            }
            // Rewrite mode scans the window in place (no 4 MiB copy);
            // tree/JSON keep the copy their whole-span scan needs.
            if case let .rewrite(classify) = mode {
                processRewrite(buffer, in: 0 ..< cut, classify: classify, into: &pending)
                buffer.removeFirst(cut)
            } else {
                let window = Array(buffer[..<cut])
                buffer.removeFirst(cut)
                processScanned(window, into: &pending)
            }
            searchStart = buffer.count
            lineBase += cut
        }
    }

    /// Pass `count` leading buffer bytes through unscanned (rewrite mode
    /// keeps them; tree/JSON print only matches, so they drop).
    private mutating func flushRaw(count: Int, into pending: inout [UInt8]) {
        guard count > 0 else { return }
        if case .rewrite = mode {
            pending.append(contentsOf: buffer[..<count])
        }
        buffer.removeFirst(count)
        searchStart = buffer.count
        lineBase += count
    }

    // MARK: Per-line output

    /// One framed line: the tree/JSON drain's complete lines, and every
    /// mode's final unterminated tail from ``finish(emit:)``. Rewrite mode's
    /// complete lines never come here — they drain as in-place regions, so
    /// no rewrite newline is re-appended here.
    private mutating func process(line: [UInt8], into pending: inout [UInt8]) {
        var content = line
        var rawHead: [UInt8] = []
        if discardingOversizedRun {
            // The line starts inside a discarded run; its remaining bytes
            // stay unscanned. A newline always breaks a run, so the flag
            // clears with this line either way.
            discardingOversizedRun = false
            let breakIndex = content.firstIndex { !MangledNameScanner.isManglingCharacter($0) } ?? content.count
            rawHead = Array(content[..<breakIndex])
            content = Array(content[breakIndex...])
            lineBase += rawHead.count
        }
        if case .rewrite = mode {
            pending.append(contentsOf: rawHead)
        }
        processScanned(content, into: &pending)
    }

    /// One rewrite span, in place: `bytes[range]` is a complete-lines
    /// region, a newline-free window of one oversized line, or the
    /// unterminated tail. A region big enough to split goes across the
    /// worker pool; everything else rewrites sequentially through the
    /// stream's engine. Identical bytes either way.
    private func processRewrite(_ bytes: [UInt8], in range: Range<Int>, classify: Bool, into pending: inout [UInt8]) {
        if let parallel, parallel.rewrite(bytes, in: range, classify: classify, style: style, palette: palette, into: &pending) {
            return
        }
        if classify {
            rewrittenClassified(bytes, in: range, into: &pending)
        } else {
            rewrittenPlain(bytes, in: range, into: &pending)
        }
    }

    /// One scanned span (a complete line's content from the per-line
    /// paths, or a mid-line window in the match-printing modes).
    private func processScanned(_ span: [UInt8], into pending: inout [UInt8]) {
        switch mode {
        case let .rewrite(classify):
            processRewrite(span, in: 0 ..< span.count, classify: classify, into: &pending)
        case .tree:
            for match in scanner.matches(inBytes: span) {
                pending.append(contentsOf: SymbolText.treeBlock(mangled: match.mangled, symbol: match.symbol).utf8)
            }
        case let .json(slim):
            // Each match re-parses into the product view for the curated
            // record fields. The scanner already validated the same string
            // through the same demangler, so the parse cannot fail;
            // compactMap keeps the graceful drop (never a trap) if that
            // invariant ever moved.
            let records = scanner.matches(inBytes: span).compactMap { match in
                DemangledSymbol(match.mangled).map { (match, $0) }
            }
            for (match, symbol) in records {
                let provenance = JSONText.Provenance(
                    line: lineNumber,
                    byteOffset: lineBase + match.byteRange.lowerBound,
                )
                let record = JSONText.symbolLine(symbol, style: style, slim: slim, provenance: provenance)
                pending.append(contentsOf: (record + "\n").utf8)
            }
        }
    }

    /// The rewrite splice: every validated mangled name replaced by its
    /// demangling in the invocation style (classify-marked when asked),
    /// colorized per the palette; a match whose rendering is empty in
    /// this style keeps its original bytes — the same contract as the
    /// library's ``MangledNameScanner/demangleAll(inBytes:style:)``, which
    /// the plain path is held byte-equal to by test.
    ///
    /// The plain (non-classify) rewrite takes the bump-arena scan (no
    /// `SwiftSymbol` tree built) over `bytes[range]` in place, splicing
    /// straight into `pending` — no intermediate output buffer, whose
    /// transient region/output pairs were the CLI filter's peak-RSS driver.
    private func rewrittenPlain(_ bytes: [UInt8], in range: Range<Int>, into pending: inout [UInt8]) {
        var cursor = range.lowerBound
        scanner.scanRendered(inBytes: bytes, in: range, style: style, engine: engine) { match, replacement in
            guard !replacement.isEmpty else { return }
            pending.append(contentsOf: bytes[cursor ..< match.lowerBound])
            pending.append(contentsOf: palette.demangled(replacement).utf8)
            cursor = match.upperBound
        }
        pending.append(contentsOf: bytes[cursor ..< range.upperBound])
    }

    /// Classify rewrite over the structured scan: each match's `SwiftSymbol`
    /// feeds the `-classify` marker computation. The structured scan takes a
    /// whole array, so the (rare) classify mode copies its span.
    private func rewrittenClassified(_ bytes: [UInt8], in range: Range<Int>, into pending: inout [UInt8]) {
        let span = Array(bytes[range])
        var cursor = 0
        for match in scanner.matches(inBytes: span) {
            let replacement = SymbolText.classifiedReplacement(match, demangled: match.demangled(style))
            guard !replacement.isEmpty else { continue }
            pending.append(contentsOf: span[cursor ..< match.byteRange.lowerBound])
            pending.append(contentsOf: palette.demangled(replacement).utf8)
            cursor = match.byteRange.upperBound
        }
        pending.append(contentsOf: span[cursor...])
    }
}
