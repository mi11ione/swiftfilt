// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

/// The mangling scheme a symbol uses (`swift::Mangle::ManglingFlavor`).
@frozen
public enum SwiftManglingFlavor: Sendable, Hashable {
    /// The stable-ABI `$s` mangling.
    case standard
    /// Embedded Swift's `$e` mangling.
    case embedded
}

/// The kind of runtime entity a symbolic reference points at
/// (`swift::Demangle::SymbolicReferenceKind`).
@frozen
public enum SymbolicReferenceKind: Sendable, Hashable {
    case context
    case accessorFunctionReference
    case uniqueExtendedExistentialTypeShape
    case nonUniqueExtendedExistentialTypeShape
    case objectiveCProtocol
}

/// Whether a symbolic reference is direct or one level of indirection
/// (`swift::Demangle::Directness`).
@frozen
public enum SymbolicReferenceDirectness: Sendable, Hashable {
    case direct
    case indirect
}

/// Resolves an in-binary symbolic reference to the demangling-tree node it
/// represents, or `nil` to refuse further demangling. `value` is the decoded
/// signed relative offset; `referenceAddress` is the VM address of the
/// reference bytes (the demangler's `baseAddress` plus the byte offset of the
/// reference within the mangled name), so the resolver can compute the target.
/// Used when demangling metadata-embedded mangled names; symbol-table
/// names contain no symbolic references.
public typealias SymbolicReferenceResolver =
    @Sendable (_ kind: SymbolicReferenceKind,
               _ directness: SymbolicReferenceDirectness,
               _ value: Int,
               _ referenceAddress: UInt64) -> SwiftSymbol?

/// Parses a Swift mangled symbol name into a structured ``SwiftSymbol`` tree.
///
/// A faithful pure-Swift reimplementation of apple/swift's
/// `lib/Demangling/Demangler.cpp` (the current `$s`/`$S`/`_T0`/`$e` grammar,
/// a postfix stack machine) and `lib/Demangling/OldDemangler.cpp` (the legacy
/// `_T` grammar still emitted for some Objective-C class names). Every entry
/// returns `nil` on input that does not parse — never a fabricated tree, never
/// a trap (the "silent skip, never silent guess" invariant).
@frozen
public struct SwiftDemangler: Sendable {
    public init() {}

    /// Every character that can follow the legacy `_T` prefix and begin a
    /// parseable production — the `_T` operator gate, derived from
    /// ``OldDemangler``'s top-level dispatch (`demangleTopLevelOld` →
    /// `demangleGlobal` → `demangleEntity` → `demangleNominalType`):
    /// `T` attribute/thunk prefixes (`_TT{S,o,O,D,d,V,R,r,W}…`), `M` type
    /// metadata, `w` value witnesses, `W` witness tables and field offsets,
    /// `t` type manglings (the ObjC-metadata `_Tt…` names), `P` partial-apply
    /// forwarders (`_TPA…`) and protocol declarations, `Z`/`F`/`v`/`I`/`i`
    /// entities (static, function, variable, initializer, subscript), and
    /// `S`/`V`/`O`/`C` nominal types (stdlib and module substitutions,
    /// struct, enum, class) — plus `0`, which is not an old operator but the
    /// Swift-4.0 `_T0` new-mangling prefix sharing the `_T` lead. No other
    /// character starts a parse (each excluded char dead-ends in that
    /// dispatch; cross-checked against `swift-demangle` and by exhaustive
    /// first-char sweep), and every included one has demangling witnesses.
    /// The old grammar keeps unparsed trailing text as a suffix, so even
    /// C-looking names like `_TSized` genuinely demangle (`Swift.Int with
    /// unmangled suffix "zed"`, exactly as `swift-demangle` prints it) —
    /// the demangler, not this set, is the authority. Single source of
    /// truth: ``MangledNameScanner``'s `_T` candidate gate consumes it too.
    @usableFromInline
    static let oldManglingOperators = "0CFIMOPSTVWZitvw"

    /// Whether `name` looks like a Swift mangled symbol — a fast prefix-only
    /// pre-filter (apple/swift's `isSwiftSymbol`) so consumers (e.g. a caller
    /// classifying a symbol table) can skip the cost of a full ``demangle(symbol:)``
    /// on the overwhelming majority of non-Swift names. Recognizes every shipped
    /// prefix era with or without the Mach-O leading underscore; the authoritative
    /// answer is still whether ``demangle(symbol:)`` returns non-`nil`. The
    /// ambiguous legacy `_T` prefix (which collides with ordinary C symbols such
    /// as `_TK_LOG…`) additionally requires a recognized old-mangling operator to
    /// follow, so this stays low-false-positive on real symbol tables.
    @inlinable
    public static func isSwiftMangled(_ name: String) -> Bool {
        if name.hasPrefix("$s") || name.hasPrefix("$S") || name.hasPrefix("$e")
            || name.hasPrefix("_$s") || name.hasPrefix("_$S") || name.hasPrefix("_$e")
            || name.hasPrefix("@__swiftmacro_")
        {
            return true
        }
        let body: Substring
        if name.hasPrefix("__T") {
            body = name.dropFirst(3)
        } else if name.hasPrefix("_T") {
            body = name.dropFirst(2)
        } else {
            return false
        }
        guard let first = body.first else { return false }
        return oldManglingOperators.contains(first)
    }

    /// The demangling tree for a mangled symbol name, or `nil` when the name
    /// does not parse under any supported dialect.
    public func demangle(symbol mangled: String) -> SwiftSymbol? {
        demangle(symbolBytes: Array(mangled.utf8))
    }

    /// A demangle attempt that also reports how far into the bytes the parser
    /// advanced — the observation seam the `explain` diagnosis reads.
    ///
    /// Pure observation: the parse and the tree it yields are identical to
    /// ``demangle(symbol:)``; `consumed` is the engine's own cursor position
    /// when the parse ended, read off the same single run — no second parse,
    /// no change to any node built. On a failed parse `consumed` is the byte
    /// index the engine could not continue past (`< bytes.count` when an
    /// unexpected byte stopped it there, `== bytes.count` when it ran out of
    /// input mid-production — the "truncated vs corrupt" seam); on success it
    /// is where the parse came to rest. Positions index the UTF-8 bytes of
    /// `mangled` exactly as passed.
    ///
    /// One caveat: the legacy `_T` grammar (not the `_T0` new-mangling) runs
    /// on the old-mangling grammar's separate scanner, which does not advance
    /// this cursor — so `consumed` stays `0` for a legacy name whether it
    /// parses or not. The current-grammar eras (`$s`/`$S`/`$e`/`_T0`, macro
    /// names) track it faithfully.
    public func demangleReportingProgress(symbol mangled: String) -> (symbol: SwiftSymbol?, consumed: Int) {
        var demangler = Demangler(text: Array(mangled.utf8), nb: SwiftSymbolBuilder())
        let node = demangler.demangleSymbol()
        return (node?.symbol, demangler.pos)
    }

    /// The demangling tree for a mangled *type* (no global prefix), or `nil`.
    public func demangle(type mangled: String) -> SwiftSymbol? {
        var demangler = Demangler(text: Array(mangled.utf8), nb: SwiftSymbolBuilder())
        return demangler.demangleType()?.symbol
    }

    /// The demangling tree for a mangled symbol name, resolving any embedded
    /// symbolic references through `resolveSymbolicReference`. `baseAddress` is
    /// the VM address the mangled bytes live at (used to compute reference
    /// targets); pass `0` for free-standing strings.
    public func demangle(
        symbolBytes bytes: [UInt8],
        baseAddress: UInt64 = 0,
        resolveSymbolicReference: SymbolicReferenceResolver? = nil,
    ) -> SwiftSymbol? {
        var demangler = Demangler(text: bytes, nb: SwiftSymbolBuilder())
        demangler.baseAddress = baseAddress
        demangler.symbolicReferenceResolver = resolveSymbolicReference
        return demangler.demangleSymbol()?.symbol
    }

    /// The demangling tree for a mangled *type* (no global prefix) carried as
    /// raw bytes, resolving any embedded symbolic references through
    /// `resolveSymbolicReference`. `baseAddress` is the VM address the bytes
    /// live at, so references compute their targets correctly. This is the
    /// reflection-metadata entry: field, superclass, associated-type, and
    /// generic mangled type names are bare type manglings that embed symbolic
    /// references — the same seam as ``demangle(symbolBytes:baseAddress:resolveSymbolicReference:)``
    /// but for the type grammar rather than a global symbol.
    public func demangle(
        typeBytes bytes: [UInt8],
        baseAddress: UInt64 = 0,
        resolveSymbolicReference: SymbolicReferenceResolver? = nil,
    ) -> SwiftSymbol? {
        var demangler = Demangler(text: bytes, nb: SwiftSymbolBuilder())
        demangler.baseAddress = baseAddress
        demangler.symbolicReferenceResolver = resolveSymbolicReference
        return demangler.demangleType()?.symbol
    }
}
