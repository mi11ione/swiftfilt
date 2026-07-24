// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// `explain`: one name's full structured story — what it is when it
// demangles, and *why* when it does not. Every fact here is either the
// curated ``DemangledSymbol`` surface (on success) or a diagnosis read
// from the engine's own parse: which mangling era the name declares, how
// far the parser advanced, and what stopped it — the introspection the
// two-case ``DemangleError`` taxonomy cannot carry on its own. Pure
// Swift, zero imports, like the rest of the library.

/// The mangling scheme (prefix family) a name declares — the "era" a
/// symbol was minted in.
///
/// Detected from the leading bytes alone (with or without the Mach-O
/// leading underscore, and the doubled `__T…` form): the same prefix set
/// ``isSwiftMangled(_:)`` recognizes, split into the families a reader
/// thinks in. A non-`nil` era means the name *claims* to be Swift; whether
/// it *parses* is a separate question the demangler answers.
public enum ManglingEra: Sendable, Hashable, CaseIterable {
    /// The stable-ABI mangling — `$s` (current) or `$S` (its transitional
    /// spelling). The overwhelming majority of shipped Swift symbols.
    case stableABI
    /// Embedded Swift's `$e` mangling.
    case embedded
    /// The Swift 4.0 `_T0` mangling — the first of the current grammar
    /// family, sharing the legacy `_T` lead.
    case swift4
    /// The legacy Swift ≤3 `_T` grammar, including the `_Tt` class and
    /// protocol type names Objective-C metadata still carries.
    case legacy
    /// A macro-expansion name — `@__swiftmacro_…`.
    case macro

    /// The stable machine name of this era — the `era` field of `swiftfilt
    /// explain --json` (`"stableABI"`, `"embedded"`, `"swift4"`,
    /// `"legacy"`, `"macro"`). Held stable across releases.
    public var name: String {
        switch self {
        case .stableABI: "stableABI"
        case .embedded: "embedded"
        case .swift4: "swift4"
        case .legacy: "legacy"
        case .macro: "macro"
        }
    }

    /// The canonical bare prefix of this era (no Mach-O underscore).
    public var prefix: String {
        switch self {
        case .stableABI: "$s"
        case .embedded: "$e"
        case .swift4: "_T0"
        case .legacy: "_T"
        case .macro: "@__swiftmacro_"
        }
    }

    /// A human label naming the era and its prefix, e.g.
    /// `"stable-ABI ($s)"` — the spelling `explain` prints.
    public var label: String {
        switch self {
        case .stableABI: "stable-ABI ($s)"
        case .embedded: "Embedded Swift ($e)"
        case .swift4: "Swift 4 (_T0)"
        case .legacy: "legacy Swift ≤3 (_T)"
        case .macro: "macro expansion (@__swiftmacro_)"
        }
    }

    /// The mangling era `name` declares, or `nil` when it carries no
    /// recognized Swift mangling prefix. Mirrors ``isSwiftMangled(_:)``'s
    /// prefix recognition exactly — a non-`nil` result here is precisely
    /// when that predicate is `true` — but names the family.
    public static func detected(in name: String) -> ManglingEra? {
        if name.hasPrefix("@__swiftmacro_") { return .macro }
        // The Mach-O leading underscore rides in front of the `$`-prefixes.
        var head = Substring(name)
        if head.hasPrefix("_$") { head = head.dropFirst() }
        if head.hasPrefix("$s") || head.hasPrefix("$S") { return .stableABI }
        if head.hasPrefix("$e") { return .embedded }
        // The `_T` family, with the doubled Mach-O `__T…` form folded in.
        var old = Substring(name)
        if old.hasPrefix("__T") { old = old.dropFirst() }
        guard old.hasPrefix("_T") else { return nil }
        if old.hasPrefix("_T0") { return .swift4 }
        guard let op = old.dropFirst(2).first,
              SwiftDemangler.oldManglingOperators.contains(op) else { return nil }
        return .legacy
    }
}

/// One name's full structured story — the model behind `swiftfilt
/// explain`, and the introspection a symbol pipeline needs when a demangle
/// *fails*.
///
/// ```swift
/// switch SymbolExplanation(parsing: name).outcome {
/// case let .demangled(symbol):       // it is Swift and it parsed
///     use(symbol)                    // the full curated surface
/// case let .malformed(diagnosis):    // it claims to be Swift but is broken
///     log(diagnosis.reason, at: diagnosis.stoppedAtByteOffset)
/// case let .notSwiftMangled(foreign):
///     handOff(to: foreign)           // c++filt / rustfilt, or show raw
/// }
/// ```
///
/// On success ``outcome`` carries the ``DemangledSymbol`` — every curated
/// field, every rendering, the identity key. On failure it carries a
/// diagnosis the two-case ``DemangleError`` cannot: the detected ``era``,
/// the byte the parser could not advance past, whether the break looks
/// like truncation or a stray byte, and any complete Swift name found
/// *inside* the input (the nearest-miss that turns "this whole thing isn't
/// one symbol" into "…but it contains one").
public struct SymbolExplanation: Sendable, Hashable {
    /// The name this explanation was built from, byte-for-byte.
    public let mangledName: String

    /// The mangling era the name declares, or `nil` when it carries no
    /// recognized Swift mangling prefix (in which case ``outcome`` is
    /// ``Outcome/notSwiftMangled(_:)``).
    public let era: ManglingEra?

    /// What the name turned out to be.
    public let outcome: Outcome

    /// The three ways a name resolves under `explain`.
    public enum Outcome: Sendable, Hashable {
        /// It is a Swift mangling and it parsed — the full curated symbol.
        case demangled(DemangledSymbol)
        /// It carries no Swift mangling prefix. The payload is a guess at
        /// which *other* toolchain minted it, when the bytes look like a
        /// known foreign scheme — a hand-off hint, never a claim.
        case notSwiftMangled(ForeignMangling?)
        /// It carries a Swift mangling prefix but the grammar parse failed —
        /// a corrupt or truncated name. The payload says how far the parse
        /// got and what stopped it.
        case malformed(Malformed)
    }

    /// Why a Swift-prefixed name did not parse, and how far it got.
    public struct Malformed: Sendable, Hashable {
        /// The byte offset (into ``mangledName``'s UTF-8) the parser could
        /// not advance past — where the break is. A diagnostic position,
        /// not a stability contract: it can shift as the grammar evolves.
        public let stoppedAtByteOffset: Int
        /// The nature of the break at ``stoppedAtByteOffset``.
        public let reason: Reason
        /// Complete Swift names found *within* the input, if any — the
        /// nearest miss. Non-empty when the whole string is not one symbol
        /// but embeds one or more (a symbol with trailing log noise, two
        /// names glued together): scan them out with ``MangledNameScanner``.
        public let embeddedSymbols: [String]
    }

    /// The specific break in a ``malformed`` name.
    public enum Reason: Sendable, Hashable {
        /// Nothing but a mangling prefix — no symbol body at all (`"$s"`).
        case emptyBody
        /// A length-prefixed identifier declares more bytes than remain —
        /// the signature of a name cut short (a frame truncated in a
        /// fixed-width log column). `declaredLength` bytes were asked for,
        /// `availableBytes` were left.
        case truncatedIdentifier(declaredLength: Int, availableBytes: Int)
        /// The parser reached the end of the input still expecting more —
        /// a production left unfinished (a trailing operator with no
        /// operand).
        case incompleteInput
        /// A byte where the grammar expects a different one — a stray or
        /// corrupt byte at ``Malformed/stoppedAtByteOffset``. Swift
        /// identifiers are punycode-encoded ASCII, so a raw non-ASCII byte
        /// (an emoji pasted into a name) lands here too.
        case unexpectedByte(UInt8)

        /// The grammar could not parse the name and no byte-precise stop
        /// position is available — the legacy `_T` grammar parses on a
        /// separate scanner that exposes no cursor, so a legacy name that
        /// fails reports this rather than a fabricated offset.
        /// ``Malformed/stoppedAtByteOffset`` is `0` and not meaningful here.
        case unparseable
    }

    /// A foreign mangling scheme a non-Swift name resembles — the next
    /// demangler to try. A prefix-shaped guess, offered as a hint.
    public enum ForeignMangling: Sendable, Hashable {
        /// An Itanium C++ mangling (`_Z…` / `__Z…`) — pipe through `c++filt`.
        case cxxItanium
        /// A Rust v0 mangling (`_R…`) — pipe through `rustfilt`.
        case rust

        /// The tool that demangles this scheme.
        public var tool: String {
            switch self {
            case .cxxItanium: "c++filt"
            case .rust: "rustfilt"
            }
        }

        /// A human label naming the scheme and its tool.
        public var label: String {
            switch self {
            case .cxxItanium: "C++ (Itanium _Z) — try c++filt"
            case .rust: "Rust (_R) — try rustfilt"
            }
        }
    }

    /// Explains `mangledName`: demangles it, or diagnoses why it does not.
    public init(parsing mangledName: String) {
        self.mangledName = mangledName
        let detectedEra = ManglingEra.detected(in: mangledName)
        era = detectedEra

        // Success is exactly the curated tier's success: the `__T…` Mach-O
        // adapter and every era `demangle(_:)` accepts.
        if let symbol = DemangledSymbol(mangledName) {
            outcome = .demangled(symbol)
            return
        }

        // No recognized Swift prefix — not a Swift symbol at all.
        guard let detectedEra else {
            outcome = .notSwiftMangled(Self.foreignMangling(of: mangledName))
            return
        }

        // Legacy `_T` names parse on the OldDemangler's own scanner, which
        // exposes no cursor — so there is no honest byte position to report.
        // Diagnose the era and any embedded name, but not a fabricated stop.
        guard detectedEra != .legacy else {
            outcome = .malformed(Malformed(
                stoppedAtByteOffset: 0,
                reason: .unparseable,
                embeddedSymbols: Self.embeddedSymbols(in: mangledName),
            ))
            return
        }

        // Malformed: read the engine's cursor. The `__T…` adapter drops one
        // Mach-O underscore before the engine sees the name (as the product
        // demangle does), so shift the reported offset back to index the
        // original bytes.
        let adapted = mangledName.hasPrefix("__T")
        let probeName = adapted ? String(mangledName.dropFirst()) : mangledName
        let shift = adapted ? 1 : 0
        let probeBytes = Array(probeName.utf8)
        let (_, consumed) = SwiftDemangler().demangleReportingProgress(symbol: probeName)
        let stoppedInProbe = min(max(consumed, 0), probeBytes.count)
        outcome = .malformed(Malformed(
            stoppedAtByteOffset: min(stoppedInProbe + shift, Array(mangledName.utf8).count),
            reason: Self.reason(probeBytes: probeBytes, stoppedAt: stoppedInProbe, era: detectedEra),
            embeddedSymbols: Self.embeddedSymbols(in: mangledName),
        ))
    }

    /// The break diagnosis at `stoppedAt` in `probeBytes` (`stoppedAt` is
    /// clamped into `0...probeBytes.count` by the caller). Truncated
    /// identifiers are read straight from the mangling's own length encoding
    /// (the digit run the engine had just consumed when it stopped);
    /// everything else is classified by where the cursor came to rest.
    static func reason(probeBytes: [UInt8], stoppedAt: Int, era: ManglingEra) -> Reason {
        // Nothing beyond the prefix: an empty body (the input is no longer
        // than the era's prefix, and the cursor reached its end).
        if probeBytes.count <= prefixByteLength(era), stoppedAt >= probeBytes.count {
            return .emptyBody
        }
        // A length-prefixed identifier the parser could not fill: the digit
        // run ending at the stop is the length it had just read.
        if let truncation = truncatedIdentifier(probeBytes: probeBytes, stoppedAt: stoppedAt) {
            return truncation
        }
        // A byte the grammar did not expect, still inside the input.
        if stoppedAt < probeBytes.count {
            return .unexpectedByte(probeBytes[stoppedAt])
        }
        // The cursor is at the end with a production still unfinished.
        return .incompleteInput
    }

    /// The truncated-identifier reason when a decimal length ends exactly at
    /// `stoppedAt` — the run the engine consumed to size an identifier it
    /// then could not read — else `nil` (no digit run precedes the stop).
    /// The length is parsed saturating at the input size: a real identifier
    /// length never exceeds the bytes it names, so anything past the whole
    /// input reports as `Int.max` ("more than remains") without overflowing.
    static func truncatedIdentifier(probeBytes: [UInt8], stoppedAt: Int) -> Reason? {
        let zero = UInt8(ascii: "0"), nine = UInt8(ascii: "9")
        var start = stoppedAt
        // The `start > 0` guard also makes `stoppedAt == 0` fall straight
        // through to the no-digit-run return below (no index underflow).
        while start > 0, probeBytes[start - 1] >= zero, probeBytes[start - 1] <= nine {
            start -= 1
        }
        guard start < stoppedAt else { return nil } // no digit run before the stop
        let available = probeBytes.count - stoppedAt
        var declared = 0
        for i in start ..< stoppedAt {
            declared = declared * 10 + Int(probeBytes[i] - zero)
            if declared > probeBytes.count {
                return .truncatedIdentifier(declaredLength: Int.max, availableBytes: available)
            }
        }
        return .truncatedIdentifier(declaredLength: declared, availableBytes: available)
    }

    /// Bytes of the prefix for `era` — used only to recognise an
    /// otherwise-empty body, and only ever for the cursor-tracking modern
    /// eras (a legacy name reports ``Reason/unparseable`` before this is
    /// consulted, so `.legacy` rides the shared 2-byte arm).
    static func prefixByteLength(_ era: ManglingEra) -> Int {
        switch era {
        case .stableABI, .embedded, .legacy: 2 // $s / $e
        case .swift4: 3 // _T0
        case .macro: 14 // @__swiftmacro_
        }
    }

    /// Complete, distinct Swift names embedded in `name` that are not the
    /// whole string — the nearest-miss list. Empty when nothing parses
    /// inside it.
    static func embeddedSymbols(in name: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for match in MangledNameScanner().matches(in: name) where match.mangled != name {
            if seen.insert(match.mangled).inserted { result.append(match.mangled) }
        }
        return result
    }

    /// A foreign mangling scheme `name` resembles, for the hand-off hint.
    static func foreignMangling(of name: String) -> ForeignMangling? {
        if name.hasPrefix("_Z") || name.hasPrefix("__Z") { return .cxxItanium }
        if name.hasPrefix("_R") { return .rust }
        return nil
    }

    // MARK: Convenience

    /// The demangled symbol when the name parsed, else `nil`.
    public var demangledSymbol: DemangledSymbol? {
        if case let .demangled(symbol) = outcome { return symbol }
        return nil
    }

    /// The failure diagnosis when the name carries a Swift prefix but did
    /// not parse, else `nil` — the malformed twin of ``demangledSymbol``.
    public var malformed: Malformed? {
        if case let .malformed(malformed) = outcome { return malformed }
        return nil
    }

    /// Whether the name carries a Swift mangling prefix but failed to parse.
    public var isMalformed: Bool {
        malformed != nil
    }
}
