// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// `swiftfilt explain <symbol>…` — one name's full structured story,
// human-formatted. On success: the era, the curated classification, and
// every validated rendering plus the identity key. On failure: the
// diagnosis the CLI used to discard — is it even Swift, which era, where
// the parse stopped and why, any complete name embedded inside, and which
// other demangler to try. A thin presenter over the library's
// ``SymbolExplanation``; it computes nothing the library does not.

import SwiftFilt

/// The `explain` verb: renders ``SymbolExplanation`` for each argument.
public enum ExplainCommand {
    /// The label column width for the aligned two-column blocks. Every
    /// field label fits (`unqualified` is the widest at 11).
    private static let labelWidth = 13

    /// Run one `explain` invocation: each symbol on its own block, in order.
    /// Human text by default; NDJSON under `--json`. Symbols come from the
    /// arguments, or — when none are given — from standard input, one symbol
    /// per line (the `nm | grep | swiftfilt explain` shape; empty lines are
    /// skipped). Always exits success (a non-demangling symbol is
    /// *explained*, never an error).
    public static func run(
        _ invocation: ExplainInvocation,
        input: () -> [UInt8]?,
        writeOutput: ([UInt8]) -> Void,
        standardOutputIsTTY: Bool,
    ) -> Int32 {
        let palette = Palette(enabled: !invocation.json && invocation.color.resolved(standardOutputIsTTY: standardOutputIsTTY))
        let symbols = invocation.symbols.isEmpty ? StreamLines.read(input) : invocation.symbols
        for argument in symbols {
            let (name, sigilRestored) = accepted(argument)
            let explanation = SymbolExplanation(parsing: name)
            if invocation.json {
                writeOutput(Array((JSONText.explainLine(explanation, slim: invocation.slim) + "\n").utf8))
            } else {
                writeOutput(Array(block(explanation, sigilRestored: sigilRestored, palette: palette).utf8))
            }
        }
        return CLI.exitSuccess
    }

    /// The name to explain and whether a `$` was restored: `swift-demangle`'s
    /// sigil-less convenience, applied only when the bare form carries no
    /// prefix and the `$`-restored form actually demangles — so a genuinely
    /// broken `$s…` name is diagnosed as given, never silently rewritten.
    static func accepted(_ argument: String) -> (name: String, sigilRestored: Bool) {
        guard !SwiftDemangler.isSwiftMangled(argument) else { return (argument, false) }
        let twin = "$" + argument
        if DemangledSymbol(twin) != nil { return (twin, true) }
        return (argument, false)
    }

    /// The human block for one explanation, ending in a blank separator
    /// line (the tree-dump convention), so consecutive blocks read apart.
    static func block(_ explanation: SymbolExplanation, sigilRestored: Bool, palette: Palette) -> String {
        var out = palette.heading(explanation.mangledName) + "\n"
        if sigilRestored {
            out += field("note", "read as $-prefixed (a leading $ was restored)")
        }
        switch explanation.outcome {
        case let .demangled(symbol):
            out += demangledBlock(symbol, era: explanation.era)
        case let .malformed(malformed):
            out += malformedBlock(malformed, era: explanation.era, byteCount: Array(explanation.mangledName.utf8).count)
        case let .notSwiftMangled(foreign):
            out += notSwiftBlock(foreign, mangled: explanation.mangledName)
        }
        return out + "\n"
    }

    private static func demangledBlock(_ symbol: DemangledSymbol, era: ManglingEra?) -> String {
        var out = field("status", "demangled")
        if let era { out += field("era", era.label) }
        out += field("kind", "\(symbol.kind)")
        if let module = symbol.module { out += field("module", module) }
        if !symbol.path.isEmpty { out += field("path", symbol.path.joined(separator: ".")) }
        let flags = flagList(symbol)
        if !flags.isEmpty { out += field("flags", flags.joined(separator: ", ")) }
        if let origin = symbol.genericOrigin { out += field("origin", origin) }
        if let suffix = symbol.suffix { out += field("suffix", suffix) }
        out += field("full", symbol.rendered(.full))
        out += field("simplified", symbol.rendered(.simplified))
        out += field("qualified", symbol.rendered(.qualified))
        out += field("unqualified", symbol.rendered(.unqualified))
        out += field("identity", symbol.identityKey.rawValue)
        return out
    }

    private static func malformedBlock(_ malformed: SymbolExplanation.Malformed, era: ManglingEra?, byteCount: Int) -> String {
        var out = field("status", "malformed — carries a Swift prefix but does not parse")
        if let era { out += field("era", era.label) }
        // The legacy grammar offers no cursor, so `.unparseable` carries no
        // meaningful byte position — omit the parse line there.
        if malformed.reason != .unparseable {
            out += field("parse", "stopped at byte \(malformed.stoppedAtByteOffset) of \(byteCount)")
        }
        for (i, line) in reasonLines(malformed.reason).enumerated() {
            out += field(i == 0 ? "reason" : "", line)
        }
        if !malformed.embeddedSymbols.isEmpty {
            out += field("contains", "\(malformed.embeddedSymbols.count) complete Swift name\(malformed.embeddedSymbols.count == 1 ? "" : "s") — the whole string is not one symbol:")
            for embedded in malformed.embeddedSymbols {
                // Every embedded name is a scanner-validated mangling, so
                // demangleAll always renders it (no lossy fallback path).
                out += field("", "\(embedded)  →  \(SwiftFilt.demangleAll(in: embedded))")
            }
            out += field("hint", "extract embedded names with the filter: swiftfilt < file")
        }
        return out
    }

    private static func notSwiftBlock(_ foreign: SymbolExplanation.ForeignMangling?, mangled: String) -> String {
        var out = field("status", "not a Swift mangled name — no recognized mangling prefix")
        if let foreign {
            out += field("looks like", foreign.label)
            out += field("hint", "\(mangled) | \(foreign.tool)")
        } else {
            out += field("hint", "hand it to another demangler, or show it raw")
        }
        return out
    }

    /// The human sentence(s) for a break reason; the first is labeled
    /// `reason`, any continuation aligns under it.
    static func reasonLines(_ reason: SymbolExplanation.Reason) -> [String] {
        switch reason {
        case .emptyBody:
            ["only a mangling prefix, with no symbol body"]
        case let .truncatedIdentifier(declaredLength, availableBytes):
            [declaredLength == Int.max
                ? "an identifier declares an implausibly large length, far past the \(availableBytes) byte\(availableBytes == 1 ? "" : "s") remaining"
                : "an identifier declares \(declaredLength) bytes but only \(availableBytes) remain",
                "likely a name cut short — a frame truncated in a fixed-width log column"]
        case .incompleteInput:
            ["the input ends mid-symbol — a production is left unfinished (a trailing operator with no operand)"]
        case let .unexpectedByte(byte):
            [printableByte(byte)]
        case .unparseable:
            ["the legacy _T grammar could not parse this name (no byte-precise position is available for it)"]
        }
    }

    /// A one-line description of an unexpected byte, naming non-ASCII bytes
    /// by their value (Swift identifiers are punycode-encoded ASCII, so a
    /// raw byte ≥ 0x80 is never valid mangling).
    static func printableByte(_ byte: UInt8) -> String {
        if byte >= 0x20, byte < 0x7F {
            return "an unexpected byte '\(Character(UnicodeScalar(byte)))' (0x\(hex(byte))) where the grammar expects a different one"
        }
        let note = byte >= 0x80 ? " — a raw non-ASCII byte (identifiers are punycode, not UTF-8)" : ""
        return "an unexpected byte 0x\(hex(byte)) where the grammar expects a different one\(note)"
    }

    /// The compiler-generated flag list for the demangled block.
    static func flagList(_ symbol: DemangledSymbol) -> [String] {
        var flags: [String] = []
        if symbol.isStatic { flags.append("static") }
        if symbol.isThunk { flags.append("thunk") }
        if symbol.isSpecialized { flags.append("specialized") }
        if symbol.isCompilerGenerated { flags.append("compiler-generated") }
        return flags
    }

    /// `"  " + label`, padded to the value column (at least one space, so
    /// an over-wide label never abuts its value).
    static func field(_ label: String, _ value: String) -> String {
        "  " + label + String(repeating: " ", count: max(1, labelWidth - label.count)) + value + "\n"
    }

    /// Two-digit lowercase hex.
    static func hex(_ byte: UInt8) -> String {
        let digits = Array("0123456789abcdef")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0xF)]])
    }
}
