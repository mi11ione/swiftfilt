// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// Finding mangled names inside arbitrary text. The scanner is what crash
// SDKs and log filters reimplement with regexes; here candidates are
// grammar-grounded and every candidate is validated through the actual
// demangler, which is both cheap and definitionally correct.

/// Finds Swift mangled names embedded in arbitrary text — crash-log
/// frames, `nm`/linker output, ANSI-colored build logs — and demangles
/// them in place.
///
/// ```swift
/// let scanner = MangledNameScanner()
/// scanner.demangleAll(in: #""_$s4main3fooyyF", referenced from:"#)
/// // ""main.foo() -> ()", referenced from:"
/// ```
///
/// **How candidates are found.** A candidate starts at any occurrence of a
/// shipped mangling prefix — `$s`, `$S`, `$e` (each optionally behind the
/// Mach-O `_`), `_T0`, legacy `_T` followed by a recognized old-mangling
/// operator (so `_TK_LOGGING`-style C names are never even attempted), or
/// `@__swiftmacro_` — and extends over the mangling character set
/// `[A-Za-z0-9_$.]`: identifier/operator bytes per the grammar, `$` from
/// the prefix family, and `.` because linker-level symbols carry
/// `.resume.N`/`.cold.N`-style suffixes that demangle as part of the name.
/// Trailing dots are trimmed (a real suffix never ends in one), so a
/// symbol at the end of a sentence does not swallow the period. Prefixes
/// match anywhere, exactly like `swift-demangle`'s stream filter — a
/// symbol glued behind other characters (`_OBJC_CLASS_$__TtC…`) is still
/// found.
///
/// **How false positives die.** Every candidate must demangle through the
/// real parser and render non-empty in ``DemangleStyle/full``; anything
/// else — English prose, C++ `_Z` names, base64 that happens to contain
/// `_T0`, hex, URLs — is left byte-for-byte untouched. There is no
/// heuristic scoring to tune and no regex to drift. Two inherent caveats,
/// both shared with `swift-demangle` itself: a string that *is* a valid
/// short mangling (like `$ss` inside `dollar$ss`) demangles — the grammar
/// cannot distinguish it from a real symbol; and for the rare
/// specialization whose constant-propagated payload the printer must emit
/// as a raw mangled name, that embedded name is itself a valid mangling,
/// so one rewriting pass produces text a second pass would demangle
/// further (7 of the 10,105 golden-corpus symbols; every other output is
/// a fixed point of ``demangleAll(in:style:)``).
///
/// Scanning is byte-oriented, linear in the text, and only runs the
/// demangler at prefix hits.
///
/// **Byte-level entry points.** ``matches(inBytes:)`` and
/// ``demangleAll(inBytes:style:)`` scan raw bytes directly — the surface
/// for log pipelines that must stay binary-safe (crash logs and build
/// logs carry invalid UTF-8). Mangled names are pure ASCII, so candidates
/// are exact in any byte stream, and every byte that is not part of a
/// validated mangling passes through untouched — byte-for-byte, with no
/// lossy Unicode decode anywhere on the path. The `String` entry points
/// are thin views over the same byte scan.
public struct MangledNameScanner: Sendable {
    public init() {}

    /// One validated mangled name found in the scanned text.
    public struct Match: Sendable, Hashable {
        /// Where the mangled name sits in the scanned string; slicing the
        /// original with it yields exactly ``mangled``.
        public let range: Range<String.Index>

        /// The mangled name as matched.
        public let mangled: String

        /// The demangling tree (validation already proved it parses).
        public let symbol: SwiftSymbol

        /// The ``DemangleStyle/full`` rendering the scan validated with —
        /// cached so the default filter path renders each match once, not
        /// once to validate and again to replace. Synthesized `Hashable`
        /// includes it, but it is a deterministic function of ``symbol``
        /// (equal symbol ⟹ equal rendering), so identity is exactly the
        /// pre-cache position + name + tree.
        let validatedFull: String

        /// The demangled replacement text in `style`.
        ///
        /// Guaranteed non-empty for ``DemangleStyle/full`` (that rendering
        /// is the validation gate); a degenerate tree can in principle
        /// render empty in another style, and
        /// ``MangledNameScanner/demangleAll(in:style:)`` leaves the
        /// original text in place when it does.
        public func demangled(_ style: DemangleStyle = .full) -> String {
            style == .full ? validatedFull : SwiftDemanglerPrinter().print(symbol, style: style.printerStyle)
        }

        /// The curated ``DemangledSymbol`` for this match — the already
        /// validated ``symbol`` tree lifted into the curated tier without a
        /// second demangle, so a scan reaches the curated fields and
        /// ``DemangledSymbol/identityKey`` in one pass.
        public var demangledSymbol: DemangledSymbol {
            DemangledSymbol(symbol, mangledName: mangled)
        }

        /// The crash-grouping ``DemangledSymbol/IdentityKey`` for this
        /// match — computed from the already-built tree, so grouping a
        /// scanned log needs no re-demangle per frame.
        public var identityKey: DemangledSymbol.IdentityKey {
            demangledSymbol.identityKey
        }
    }

    /// One validated mangled name found in scanned bytes — the byte-level
    /// twin of ``Match`` for binary-safe pipelines. `byteRange` indexes the
    /// scanned byte array; `mangled` is pure ASCII by construction, so it
    /// equals the bytes of the range decoded as UTF-8.
    public struct ByteMatch: Sendable, Hashable {
        /// Where the mangled name sits in the scanned bytes; slicing the
        /// scanned array with it yields exactly the bytes of ``mangled``.
        public let byteRange: Range<Int>

        /// The mangled name as matched (always pure ASCII).
        public let mangled: String

        /// The demangling tree (validation already proved it parses).
        public let symbol: SwiftSymbol

        /// The ``DemangleStyle/full`` rendering the scan validated with —
        /// see ``MangledNameScanner/Match/validatedFull``. Synthesized
        /// `Hashable` includes it, but it is a deterministic function of
        /// ``symbol``, so identity is exactly the pre-cache byte range +
        /// name + tree.
        let validatedFull: String

        /// The demangled replacement text in `style` — the same contract
        /// as ``MangledNameScanner/Match/demangled(_:)``: guaranteed
        /// non-empty for ``DemangleStyle/full``, possibly empty for a
        /// degenerate tree in another style (in which case the replacing
        /// entry points leave the original bytes in place).
        public func demangled(_ style: DemangleStyle = .full) -> String {
            style == .full ? validatedFull : SwiftDemanglerPrinter().print(symbol, style: style.printerStyle)
        }

        /// The curated ``DemangledSymbol`` for this match — the already
        /// validated ``symbol`` tree lifted into the curated tier without a
        /// second demangle (the binary-safe twin of
        /// ``MangledNameScanner/Match/demangledSymbol``).
        public var demangledSymbol: DemangledSymbol {
            DemangledSymbol(symbol, mangledName: mangled)
        }

        /// The crash-grouping ``DemangledSymbol/IdentityKey`` for this
        /// match — computed from the already-built tree.
        public var identityKey: DemangledSymbol.IdentityKey {
            demangledSymbol.identityKey
        }
    }

    /// Every validated mangled name in `text`, in order, non-overlapping
    /// (scanning resumes after each match).
    public func matches(in text: String) -> [Match] {
        var result: [Match] = []
        let utf8 = text.utf8
        // Matches are ordered, so each index advances from the previous
        // one — a single pass over the string.
        var cursor = utf8.startIndex
        var cursorOffset = 0
        for raw in matches(inBytes: Array(utf8)) {
            let start = utf8.index(cursor, offsetBy: raw.byteRange.lowerBound - cursorOffset)
            let end = utf8.index(start, offsetBy: raw.byteRange.count)
            cursor = end
            cursorOffset = raw.byteRange.upperBound
            // Candidates are pure ASCII, and an ASCII byte is always a
            // scalar boundary, so these positions exist in the String view.
            guard let lower = start.samePosition(in: text),
                  let upper = end.samePosition(in: text) else { continue }
            result.append(Match(range: lower ..< upper, mangled: raw.mangled, symbol: raw.symbol,
                                validatedFull: raw.validatedFull))
        }
        return result
    }

    /// A copy of `text` with every validated mangled name replaced by its
    /// demangled form in `style`; text without valid manglings comes back
    /// unchanged. Matches that render empty in `style` (degenerate trees
    /// outside the validating ``DemangleStyle/full`` rendering) are left
    /// as their original mangled text rather than deleted.
    public func demangleAll(in text: String, style: DemangleStyle = .full) -> String {
        String(decoding: demangleAll(inBytes: Array(text.utf8), style: style), as: UTF8.self)
    }

    // MARK: Byte-level scan

    /// The scan core: find every validated mangled name in `bytes`, in
    /// order, non-overlapping (scanning resumes after each match), handing
    /// each to `body` as it is found — so callers that consume matches one
    /// at a time (the splicing filter) never hold every tree at once.
    /// Candidates parse straight from the byte slice (their `mangled`
    /// string is built only for validated matches; candidates are pure
    /// ASCII, so slice bytes and string UTF-8 are the same bytes), and the
    /// validating ``DemangleStyle/full`` rendering rides along in the
    /// match rather than being re-printed later.
    private func scanMatches(inBytes bytes: [UInt8], _ body: (ByteMatch) -> Void) {
        var i = 0
        let count = bytes.count
        let demangler = SwiftDemangler()
        let printer = SwiftDemanglerPrinter()
        while i < count {
            let prefixLength = Self.prefixLength(in: bytes, at: i)
            guard prefixLength > 0 else { i += 1; continue }
            var j = i + prefixLength
            while j < count, Self.isManglingCharacter(bytes[j]) {
                j += 1
            }
            // A real LLVM suffix never ends in a dot; trailing dots are
            // sentence punctuation.
            while j > i + prefixLength, bytes[j - 1] == UInt8(ascii: ".") {
                j -= 1
            }
            // Same accept/reject shape as the original scan: a candidate
            // that parses and renders non-empty in `.full` is a match and
            // the cursor jumps past it; anything else advances one byte.
            // The `.full` rendering is bound here (`case let`) so it rides
            // along in the match rather than being re-printed downstream.
            if let tree = demangler.demangle(symbolBytes: Array(bytes[i ..< j])),
               case let rendered = printer.print(tree, style: .full),
               !rendered.isEmpty
            {
                body(ByteMatch(
                    byteRange: i ..< j,
                    mangled: String(decoding: bytes[i ..< j], as: UTF8.self),
                    symbol: tree,
                    validatedFull: rendered,
                ))
                i = j
            } else {
                i += 1
            }
        }
    }

    /// The rewrite scan core: the same candidate-finding as ``scanMatches``,
    /// but validation and rendering run on the bump-arena ``ArenaBuilder``
    /// backend — no ``SwiftSymbol`` value tree is ever built. Each candidate is
    /// demangled once into a reused arena (reset between candidates, so the
    /// storage allocates only on the first and then never again), validated by
    /// its ``DemangleStyle/full`` rendering being non-empty (the exact accept
    /// gate ``scanMatches`` uses), and handed to `body` as its byte range plus
    /// the replacement text in `style` — which the full validation reuses when
    /// `style` is `.full`, and otherwise re-renders from the same arena tree
    /// (never a second demangle). A match whose `style` rendering is empty (a
    /// degenerate tree outside `.full`) is still reported, with an empty
    /// replacement, so the caller keeps the original bytes exactly as before.
    /// This backs the string→string rewrite entry points; the structured scan
    /// (`scanMatches`, exposing `SwiftSymbol`) is unchanged. `package` so the
    /// CLI filter's plain (non-classify) rewrite drives the same arena scan the
    /// library `demangleAll` does — one splice contract, one backend — without
    /// widening the public surface.
    package func scanRendered(inBytes bytes: [UInt8], style: DemangleStyle, _ body: (Range<Int>, String) -> Void) {
        scanRendered(inBytes: bytes, style: style, engine: ArenaDemangleEngine(), body)
    }

    /// As ``scanRendered(inBytes:style:_:)`` with a caller-held engine — the
    /// CLI's streaming filter scans one framed region per call, so per-call
    /// engine construction (arena slabs + printer buffer + demangler) was
    /// its dominant per-call cost; holding one engine across the stream
    /// amortizes it. Each call installs its own scan buffer, so calls are
    /// independent — the engine carries no cross-call parse state (pinned by
    /// the differential's session/window legs).
    package func scanRendered(inBytes bytes: [UInt8], style: DemangleStyle, engine: ArenaDemangleEngine, _ body: (Range<Int>, String) -> Void) {
        scanRendered(inBytes: bytes, in: 0 ..< bytes.count, style: style, engine: engine, body)
    }

    /// As the whole-buffer overload, restricted to `range` — the CLI's
    /// streaming filter scans its frame buffer's completed-lines region in
    /// place (no per-region byte copy; the buffer's tail beyond `range` is
    /// the partial line still accumulating). The caller guarantees `range`
    /// ends at a line boundary or at the buffer's end: a candidate can never
    /// contain or cross a `\n`, so scanning `[range]` finds exactly the
    /// whole-buffer candidates that lie inside it — pinned by the
    /// region-vs-line equivalence tests and the CLI goldens. The buffer must
    /// not be mutated until this returns (the engine windows candidates
    /// inside it; the pin is released on return).
    package func scanRendered(inBytes bytes: [UInt8], in range: Range<Int>, style: DemangleStyle, engine: ArenaDemangleEngine, _ body: (Range<Int>, String) -> Void) {
        var i = range.lowerBound
        let count = range.upperBound
        // One engine (arena + demangler + printer, each rewound in place)
        // for the whole scan, with the scan buffer installed once and every
        // candidate parsed as a *window* of it — no per-candidate engine
        // allocation and no candidate byte copy at all (the arena's
        // zero-copy identifier ranges point straight into the scan buffer).
        // Reused-engine equivalence to the fresh-engine path is pinned by
        // the differential's session/window legs and the scanner corpus
        // legs; the window's bytes are the identical slice the
        // per-candidate `Array` used to carry.
        engine.beginBuffer(bytes)
        defer { engine.endBuffer() }
        // The scan walks the raw buffer: most bytes are not symbol text, so
        // the inner skip loop (a prefix can only start at '$', '_', or '@')
        // burns one unchecked load per non-candidate byte — the per-byte
        // `prefixLength` probe through `Array`'s checked subscript framed on
        // the filter profile before this.
        bytes.withUnsafeBufferPointer { buffer in
            while i < count {
                while i < count {
                    let byte = buffer[i]
                    if byte == 0x24 || byte == 0x5F || byte == 0x40 { break } // '$' '_' '@'
                    i += 1
                }
                if i >= count { break }
                let prefixLength = Self.prefixLength(in: buffer, at: i)
                guard prefixLength > 0 else { i += 1; continue }
                var j = i + prefixLength
                while j < count, Self.isManglingCharacter(buffer[j]) {
                    j += 1
                }
                while j > i + prefixLength, buffer[j - 1] == UInt8(ascii: ".") {
                    j -= 1
                }
                if let root = engine.demangle(window: i ..< j) {
                    let full = engine.render(root, style: .full)
                    if !full.isEmpty {
                        let replacement = style == .full ? full : engine.render(root, style: style.printerStyle)
                        body(i ..< j, replacement)
                        i = j
                        continue
                    }
                }
                i += 1
            }
        }
    }

    /// Every validated mangled name in `bytes`, in order, non-overlapping
    /// (scanning resumes after each match) — the binary-safe core the
    /// `String` entry points view. Bytes outside the ASCII mangling
    /// character set (including any invalid UTF-8) can never join a
    /// candidate, so junk around symbols never perturbs a match.
    public func matches(inBytes bytes: [UInt8]) -> [ByteMatch] {
        var result: [ByteMatch] = []
        scanMatches(inBytes: bytes) { result.append($0) }
        return result
    }

    /// A copy of `bytes` with every validated mangled name replaced by the
    /// UTF-8 of its demangled form in `style` — the binary-safe filter
    /// core. Every byte that is not part of a validated mangling is copied
    /// through untouched (invalid UTF-8 included), so input without valid
    /// manglings comes back byte-identical. Matches that render empty in
    /// `style` (degenerate trees outside the validating
    /// ``DemangleStyle/full`` rendering) are left as their original
    /// mangled bytes rather than deleted.
    ///
    /// Splices as the scan advances — one live match at a time, so peak
    /// memory tracks the buffer, not the number of symbols in it.
    public func demangleAll(inBytes bytes: [UInt8], style: DemangleStyle = .full) -> [UInt8] {
        var out: [UInt8] = []
        var cursor = 0
        scanRendered(inBytes: bytes, style: style) { range, replacement in
            guard !replacement.isEmpty else { return }
            // Reserve 1.5× the input up front: demangled text is longer than
            // its mangling, so a symbol-dense log's output overshoots an
            // input-sized reserve and pays Array's doubling realloc — a
            // full-output memcpy and, transiently, BOTH buffers resident
            // (measured ≈150 MiB peak-RSS contribution on a 64 MiB log;
            // ≈95 MiB after this reserve). The extra half is virtual until
            // touched — untouched reserve pages never enter RSS — so sparse
            // logs pay nothing for it.
            if out.isEmpty { out.reserveCapacity(bytes.count + bytes.count / 2 + 64) }
            out.append(contentsOf: bytes[cursor ..< range.lowerBound])
            out.append(contentsOf: replacement.utf8)
            cursor = range.upperBound
        }
        // No match spliced anything (none found, or every rendering in
        // `style` was empty): the input comes back unchanged, exactly as
        // before.
        guard cursor > 0 else { return bytes }
        out.append(contentsOf: bytes[cursor...])
        return out
    }

    /// Whether `byte` belongs to the candidate character set a mangled
    /// name extends over: identifier/operator bytes per the mangling
    /// grammar, `$` (prefixes), and `.` (unmangled suffixes).
    ///
    /// Public alongside the byte-level scan so windowed callers (streaming
    /// filters that must cut an over-long buffer) can cut *outside* a
    /// maximal mangling-character run — the only cut that provably splits
    /// no candidate.
    public static func isManglingCharacter(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A") ... UInt8(ascii: "Z"),
             UInt8(ascii: "a") ... UInt8(ascii: "z"),
             UInt8(ascii: "0") ... UInt8(ascii: "9"),
             UInt8(ascii: "_"), UInt8(ascii: "$"), UInt8(ascii: "."):
            true
        default:
            false
        }
    }

    private static let macroPrefix = Array("@__swiftmacro_".utf8)

    /// Old-mangling top-level operators — the same grammar-derived set the
    /// ``SwiftDemangler/isSwiftMangled(_:)`` gate applies after `_T` (single
    /// source of truth), keeping `_TK_LOGGING`-style C names from ever
    /// reaching the demangler while every demangleable `_T…` form starts a
    /// candidate. Validation still decides.
    private static let oldManglingOperators = Set(SwiftDemangler.oldManglingOperators.utf8)

    /// The length of the mangling prefix starting at `index`, or 0. The
    /// prefix set: `$s`/`$S`/`$e`, `_$s`/`_$S`/`_$e`, `_T0` and legacy
    /// `_T` + operator, `@__swiftmacro_`. Single logic source: the `Array`
    /// form (the structured scan) views the same buffer probe the raw-buffer
    /// filter scan uses.
    private static func prefixLength(in bytes: [UInt8], at index: Int) -> Int {
        bytes.withUnsafeBufferPointer { prefixLength(in: $0, at: index) }
    }

    private static func prefixLength(in bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Int {
        let count = bytes.count
        switch bytes[index] {
        case UInt8(ascii: "$"):
            guard index + 1 < count, isManglingFamily(bytes[index + 1]) else { return 0 }
            return 2
        case UInt8(ascii: "_"):
            guard index + 2 < count else { return 0 }
            if bytes[index + 1] == UInt8(ascii: "$"), isManglingFamily(bytes[index + 2]) {
                return 3
            }
            if bytes[index + 1] == UInt8(ascii: "T"), oldManglingOperators.contains(bytes[index + 2]) {
                return 2
            }
            return 0
        case UInt8(ascii: "@"):
            guard index + macroPrefix.count <= count,
                  bytes[index ..< index + macroPrefix.count].elementsEqual(macroPrefix)
            else { return 0 }
            return macroPrefix.count
        default:
            return 0
        }
    }

    /// `s`, `S`, or `e` — the byte after `$` in every current prefix.
    private static func isManglingFamily(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "s") || byte == UInt8(ascii: "S") || byte == UInt8(ascii: "e")
    }
}
