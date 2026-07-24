// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// The tier-0 entry points: demangle a name, test a name, rewrite a text.
// Everything here is a thin, documented adapter over the corpus-validated
// engine — no new parsing, no new rendering.

/// The demangled form of a Swift mangled name, or `nil` when the name does
/// not demangle.
///
/// The tier-0 call: `demangle("$s4main3fooyyF")` returns
/// `"main.foo() -> ()"`. Accepts every shipped mangling era — stable-ABI
/// `$s`/`$S`, Embedded Swift `$e`, Swift 4 `_T0`, the legacy Swift ≤3 `_T`
/// grammar (including the `_Tt` class/protocol names ObjC metadata still
/// carries), macro-expansion `@__swiftmacro_` names — each with or without
/// the Mach-O leading underscore (`_$s…`, and the doubled `__T…` form,
/// which is adapted exactly as `swift-demangle` adapts it).
///
/// Returns `nil` for names that are not Swift manglings *and* for
/// Swift-prefixed names that fail to parse; use
/// ``demangle(validating:style:)`` or ``DemangledSymbol/init(parsing:)``
/// when the distinction matters, and ``DemangledSymbol`` when you need
/// structure instead of a string.
///
/// - Parameters:
///   - mangledName: The mangled symbol name.
///   - style: The rendering preset; ``DemangleStyle/full`` matches plain
///     `swift-demangle` output.
/// - Returns: The demangled name, or `nil` when `mangledName` does not
///   demangle (or renders to nothing under a degenerate tree — never an
///   empty string).
///
/// The whole string must be one mangled name. Rows from linker maps and
/// metadata sections often carry non-mangling wrappers (`l_$s…Hr`
/// assembler labels, `_symbolic $s…` reflection refs,
/// `_OBJC_CLASS_$__Tt…` records) — scan those with
/// ``MangledNameScanner`` (or ``demangleAll(in:style:)``), which finds
/// the embedded mangling wherever it sits.
public func demangle(_ mangledName: String, style: DemangleStyle = .full) -> String? {
    ProductDemangling.demangleToString(mangledName, style: style.printerStyle)
}

/// The demangled form of a Swift mangled name, throwing a typed
/// ``DemangleError`` that says *why* when it cannot demangle.
///
/// Identical to ``demangle(_:style:)`` on success. On failure it throws
/// ``DemangleError/notSwiftMangled`` when the input carries no Swift
/// mangling prefix (hand the name to your next demangler), or
/// ``DemangleError/malformed`` when a Swift-prefixed name fails to parse
/// (corrupt or truncated — nothing else will demangle it either).
///
/// - Parameters:
///   - mangledName: The mangled symbol name.
///   - style: The rendering preset; ``DemangleStyle/full`` matches plain
///     `swift-demangle` output.
/// - Returns: The demangled name; never empty.
/// - Throws: ``DemangleError``.
public func demangle(validating mangledName: String, style: DemangleStyle = .full) throws(DemangleError) -> String {
    guard let rendered = demangle(mangledName, style: style) else {
        throw ProductDemangling.failureReason(mangledName)
    }
    return rendered
}

/// Whether `name` looks like a Swift mangled symbol — a fast, prefix-only
/// pre-filter.
///
/// Recognizes every shipped mangling prefix era with or without the Mach-O
/// leading underscore; the ambiguous legacy `_T` prefix (which collides
/// with ordinary C names such as `_TK_LOGGING`) additionally requires a
/// recognized old-mangling operator to follow, so this stays
/// low-false-positive on real symbol tables. Use it to skip the cost of a
/// full demangle on the overwhelming majority of non-Swift names; the
/// authoritative answer is still whether ``demangle(_:style:)`` returns
/// non-`nil`.
public func isSwiftMangled(_ name: String) -> Bool {
    SwiftDemangler.isSwiftMangled(name)
}

/// A copy of `text` with every embedded Swift mangled name replaced by its
/// demangled form — the one-call text filter.
///
/// Scans arbitrary text (crash logs, `nm` output, linker errors,
/// ANSI-colored build logs) exactly as ``MangledNameScanner`` does:
/// candidates are found by mangling prefix, bounded by the mangling
/// character set, and each is *validated through the demangler* — anything
/// that fails to demangle is left untouched, so non-symbol text survives
/// byte-for-byte.
///
/// ```swift
/// demangleAll(in: "0  MyApp  0x00104abc $s4main3fooyyF + 12")
/// // "0  MyApp  0x00104abc main.foo() -> () + 12"
/// ```
///
/// - Parameters:
///   - text: Any text possibly containing mangled names.
///   - style: The rendering preset for each replacement.
/// - Returns: The rewritten text; input with no valid manglings is
///   returned unchanged.
public func demangleAll(in text: String, style: DemangleStyle = .full) -> String {
    MangledNameScanner().demangleAll(in: text, style: style)
}

/// The demangled form of a bare Swift *type* mangling — the reflection /
/// runtime type-string form that carries no global `$s` prefix, the same
/// input `swift-demangle -type` takes and `_mangledTypeName(_:)` produces.
///
/// A full symbol like `$s4main3fooyyF` names an *entity* (a function, a
/// property, a metadata record); a bare type mangling like `SaySiG` names a
/// *type* directly (`[Swift.Int]`). Reflection metadata — field, superclass,
/// associated-type, and generic type names — is written in this bare form.
/// Reach for this when you hold a type string on its own; use
/// ``demangle(_:style:)`` for a whole symbol (a `$s…` name), and
/// ``MangledNameScanner`` to find manglings embedded in arbitrary text.
///
/// ```swift
/// demangle(type: "SaySiG")                    // "[Swift.Int]"
/// demangle(type: "SiSg", style: .qualified)   // "Swift.Optional<Swift.Int>"
/// ```
///
/// Byte-for-byte `swift-demangle -type` for every input that demangles.
/// `nil` when the whole string is not exactly one complete valid type — an
/// entity mangling, a name with trailing bytes, or garbage all return `nil`,
/// where the reference prints its `<<invalid type>>` placeholder. swiftfilt
/// declines instead, so a caller can echo the input untouched rather than a
/// fabricated name (the same never-invent policy as the stream filter).
///
/// - Parameters:
///   - mangledType: A bare type mangling, with no `$s` global prefix.
///   - style: The rendering preset; ``DemangleStyle/full`` matches plain
///     `swift-demangle -type` output.
/// - Returns: The demangled type, or `nil` when `mangledType` is not exactly
///   one complete valid type.
public func demangle(type mangledType: String, style: DemangleStyle = .full) -> String? {
    guard let symbol = SwiftDemangler().demangle(type: mangledType) else { return nil }
    return SwiftDemanglerPrinter().print(symbol, style: style.printerStyle)
}

/// Shared product-tier demangling: the engine plus the one adapter the
/// engine itself does not apply.
enum ProductDemangling {
    /// Engine demangle with the Mach-O double-underscore adapter: a `__T…`
    /// name (old mangling behind an extra Mach-O underscore) demangles as
    /// its `_T…` body, exactly as `swift-demangle` treats it. All other
    /// underscore forms (`_$s`, `_$S`, `_$e`, `_T0`) are engine-native.
    ///
    /// This structured form (returning a ``SwiftSymbol`` value tree) backs the
    /// structured product surface — ``DemangledSymbol`` and friends. The
    /// string→string entry point ``demangleToString(_:style:)`` takes the
    /// allocation-free bump-arena path instead.
    static func demangle(_ name: String) -> SwiftSymbol? {
        if name.hasPrefix("__T") {
            return SwiftDemangler().demangle(symbol: String(name.dropFirst()))
        }
        return SwiftDemangler().demangle(symbol: name)
    }

    /// Demangle `name` and render it in `style` entirely on the bump-arena
    /// backend — no ``SwiftSymbol`` value tree built. Applies the same `__T…`
    /// Mach-O double-underscore adapter as ``demangle(_:)`` first, then runs the
    /// `ArenaBuilder` demangle+render. `nil` when the name does not demangle (or
    /// renders empty). This is the hot path for ``demangle(_:style:)`` and the
    /// symbol-argument string output.
    static func demangleToString(_ name: String, style: SwiftDemanglerPrinter.Style) -> String? {
        let adapted = name.hasPrefix("__T") ? String(name.dropFirst()) : name
        return ArenaDemangling.render(symbolBytes: Array(adapted.utf8), style: style)
    }

    /// The taxonomy for a name that failed to demangle: prefix present but
    /// unparseable is ``DemangleError/malformed``; anything else is
    /// ``DemangleError/notSwiftMangled``.
    static func failureReason(_ name: String) -> DemangleError {
        SwiftDemangler.isSwiftMangled(name) ? .malformed : .notSwiftMangled
    }
}
