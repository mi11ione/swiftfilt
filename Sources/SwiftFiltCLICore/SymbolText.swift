// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// The per-symbol renderings both modes share: styled demangled text,
// classify-marked text, node trees, and the one-role ANSI palette.

import SwiftFilt

/// The ANSI palette — two roles: the filter's demangled replacement and
/// the census report's section headings. Identity when disabled, and each
/// text is colorized as a whole (the escapes wrap the inserted text only,
/// so surrounding log lines and aligned columns survive byte-for-byte).
@frozen
public struct Palette: Sendable {
    /// Whether escapes are emitted.
    public let enabled: Bool

    @inlinable
    public init(enabled: Bool) {
        self.enabled = enabled
    }

    /// A demangled name inserted into filtered output: cyan.
    public func demangled(_ text: String) -> String {
        guard enabled, !text.isEmpty else { return text }
        return "\u{1B}[36m" + text + "\u{1B}[0m"
    }

    /// A census report section heading: bold. Applied to whole heading
    /// lines only, never inside aligned table rows, so escapes can never
    /// disturb the columns.
    public func heading(_ text: String) -> String {
        guard enabled, !text.isEmpty else { return text }
        return "\u{1B}[1m" + text + "\u{1B}[0m"
    }
}

/// Rendering helpers shared by the symbol-args and filter paths.
enum SymbolText {
    /// `swift-demangle`'s sigil-less convenience: a bare argument with no
    /// recognized mangling prefix is retried with `$` prepended — accepting
    /// the `s4main…`/`S…`/`e…` spellings shells and logs strip the `$` from;
    /// `nil` when `argument` already carries a prefix. The caller still
    /// echoes the ORIGINAL argument when neither form demangles; swiftfilt
    /// never prints a name the user did not give.
    static func sigilLessTwin(_ argument: String) -> String? {
        SwiftDemangler.isSwiftMangled(argument) ? nil : "$" + argument
    }

    /// The argument's demangling, through the sigil-less twin when the
    /// bare form carries no prefix — `nil` when neither form demangles.
    static func acceptedArgument(_ argument: String) -> DemangledSymbol? {
        if let direct = DemangledSymbol(argument) { return direct }
        return sigilLessTwin(argument).flatMap(DemangledSymbol.init)
    }

    static func argumentLine(_ argument: String, style: DemangleStyle, classify: Bool) -> String {
        var accepted = argument
        var rendered = SwiftFilt.demangle(argument, style: style)
        if rendered == nil, let twin = sigilLessTwin(argument),
           let viaTwin = SwiftFilt.demangle(twin, style: style)
        {
            accepted = twin
            rendered = viaTwin
        }
        let demangled = rendered ?? argument
        guard classify else { return demangled }
        // `swift-demangle` strips one leading underscore from any `__…`
        // argument BEFORE classifying (swift-demangle.cpp, `demangle()`),
        // so a Mach-O `__T…` name classifies as its `_T…` body — without
        // this the marker computation sees an unrecognized prefix and emits
        // a spurious `{N}`. Mirrors the adapter `demangle(_:style:)`.
        let markerName = accepted.hasPrefix("__") ? String(accepted.dropFirst()) : accepted
        let markers = SwiftDemanglerPrinter().classify(markerName)
        return markers.isEmpty ? demangled : markers + " " + demangled
    }

    /// The text line for one `--type` input: the bare type mangling (no `$s`
    /// prefix) demangled in `style`, or the input echoed unchanged when it is
    /// not exactly one valid type — c++filt semantics, never the reference
    /// `-type`'s `<<invalid type>>` fabrication. No sigil-less `$`-retry: a
    /// type mangling carries no `$` sigil to restore.
    static func typeArgumentLine(_ argument: String, style: DemangleStyle) -> String {
        SwiftFilt.demangle(type: argument, style: style) ?? argument
    }

    /// The classify-marked replacement for one filter-mode match: the
    /// demangling in `style` behind the marker string when one applies.
    /// `demangled` may be empty (a degenerate tree outside the validating
    /// full style); the caller leaves the original bytes in place then,
    /// exactly like the plain rewrite.
    static func classifiedReplacement(_ match: MangledNameScanner.ByteMatch, demangled: String) -> String {
        guard !demangled.isEmpty else { return demangled }
        let markers = SwiftDemanglerPrinter().classify(match.mangled, demangled: match.symbol)
        return markers.isEmpty ? demangled : markers + " " + demangled
    }

    /// The `swift-demangle -tree-only` block for one demangled symbol:
    /// the `Demangling for <mangled>` header, the engine's
    /// reference-exact node dump, and the blank separator line the
    /// reference tool ends every tree with — so `swiftfilt --tree <sym>`
    /// is byte-identical to `swift-demangle -tree-only <sym>`.
    static func treeBlock(mangled: String, symbol: SwiftSymbol) -> String {
        "Demangling for \(mangled)\n" + symbol.treeDump() + "\n"
    }
}
