// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// `swift-demangle -classify` marker computation: `{N}` (not a Swift symbol),
// `{T:target}` (a thunk and the demangled-from mangled target), `{C}` (the
// symbol does not use the Swift calling convention). A faithful port of the
// dispatch in apple/swift `tools/swift-demangle/swift-demangle.cpp` and the
// `Context::isThunkSymbol` / `getThunkTarget` / `hasSwiftCallingConvention`
// predicates in `lib/Demangling/Context.cpp`.

enum SwiftSymbolClassifier {
    /// The classification tokens for a mangled `name`, joined by `,` and wrapped
    /// in braces (`{N}`, `{T:target}`, `{C}`, `{T:target,C}`, …), or "" when none
    /// apply.
    static func classify(_ name: String) -> String {
        classify(name, demangled: SwiftDemangler().demangle(symbol: name))
    }

    /// As ``classify(_:)`` but reusing an already-computed demangle of `name`
    /// (the demangle of the original, before any stripping) — lets a caller that
    /// already demangled the symbol skip a redundant demangle.
    static func classify(_ name: String, demangled: SwiftSymbol?) -> String {
        var tokens: [String] = []
        if !isSwiftSymbol(name) { tokens.append("N") }
        if isThunkSymbol(name, demangleOfName: demangled) {
            tokens.append("T:" + thunkTargetString(name))
        }
        // `{C}` only when the name demangled (the C++ `pointer` guard) and the
        // top-level entity is a runtime accessor without the Swift convention.
        if let demangled, !hasSwiftCallingConvention(demangled) {
            tokens.append("C")
        }
        return tokens.isEmpty ? "" : "{" + tokens.joined(separator: ",") + "}"
    }

    private static func isMangledName(_ name: String) -> Bool {
        DemanglerPrefixes.manglingPrefixLength(Array(name.utf8)) != 0
    }

    /// `swift::Demangle::isSwiftSymbol`: the old `_T` function-type prefix OR any
    /// current mangling prefix. Broader than ``SwiftDemangler/isSwiftMangled(_:)``
    /// (which requires a recognized old-mangling operator after `_T`); the
    /// `{N}` marker fires exactly when this is false.
    private static func isSwiftSymbol(_ name: String) -> Bool {
        name.hasPrefix("_T") || isMangledName(name)
    }

    /// `Context::isThunkSymbol`. `demangleOfName` is reused when the stripped name
    /// equals the original (the common case), avoiding a second demangle.
    static func isThunkSymbol(_ name: String, demangleOfName: SwiftSymbol?) -> Bool {
        if isMangledName(name) {
            let stripped = stripAsyncContinuation(stripSuffix(name))
            guard stripped.hasSuffix("TA") || stripped.hasSuffix("Ta") || stripped.hasSuffix("To")
                || stripped.hasSuffix("TO") || stripped.hasSuffix("TR") || stripped.hasSuffix("Tr")
                || stripped.hasSuffix("TW") || stripped.hasSuffix("fC")
            else { return false }
            // A quick suffix match needs the full demangle to avoid false positives.
            let node = stripped == name ? demangleOfName : SwiftDemangler().demangle(symbol: stripped)
            guard let node, node.kind == .Global, let first = node.children.first else { return false }
            switch first.kind {
            case .ObjCAttribute, .NonObjCAttribute, .PartialApplyObjCForwarder, .PartialApplyForwarder,
                 .ReabstractionThunkHelper, .ReabstractionThunk, .ProtocolWitness, .Allocator:
                return true
            default:
                return false
            }
        }
        if name.hasPrefix("_T") {
            let remaining = name.dropFirst(2)
            if remaining.hasPrefix("To") || remaining.hasPrefix("TO")
                || remaining.hasPrefix("PA_") || remaining.hasPrefix("PAo_")
            {
                return true
            }
        }
        return false
    }

    /// `Context::getThunkTarget` — the mangled target of a thunk, or "" when the
    /// target is not derivable from the mangling (TR/Tr/TW, suffixed symbols).
    static func thunkTarget(_ name: String) -> String {
        guard isThunkSymbol(name, demangleOfName: SwiftDemangler().demangle(symbol: name)) else { return "" }
        return thunkTargetString(name)
    }

    /// The pure-string target derivation, assuming `name` is already known to be
    /// a thunk (no re-demangle); the `classify` path calls this after its own
    /// ``isThunkSymbol(_:demangleOfName:)`` check.
    private static func thunkTargetString(_ name: String) -> String {
        if isMangledName(name) {
            // A suffixed symbol's target is not derivable.
            if stripSuffix(name) != name { return "" }
            let stripped = stripAsyncContinuation(name)
            if stripped.hasSuffix("TR") || stripped.hasSuffix("Tr") || stripped.hasSuffix("TW") { return "" }
            if stripped.hasSuffix("fC") {
                return String(stripped.dropLast()) + "c"
            }
            return String(stripped.dropLast(2))
        }
        let remaining = name.dropFirst(2)
        if remaining.hasPrefix("PA_") { return String(remaining.dropFirst(3)) }
        if remaining.hasPrefix("PAo_") { return String(remaining.dropFirst(4)) }
        return "_T" + String(remaining.dropFirst(2))
    }

    /// `Context::hasSwiftCallingConvention` — false for the runtime accessors /
    /// witnesses that use a non-Swift convention, true for everything else.
    static func hasSwiftCallingConvention(_ global: SwiftSymbol) -> Bool {
        guard global.kind == .Global, let top = global.children.first else { return false }
        switch top.kind {
        case .TypeMetadataAccessFunction, .ValueWitness, .ProtocolWitnessTableAccessor,
             .GenericProtocolWitnessTableInstantiationFunction, .LazyProtocolWitnessTableAccessor,
             .AssociatedTypeMetadataAccessor, .AssociatedTypeWitnessTableAccessor,
             .BaseWitnessTableAccessor, .ObjCAttribute:
            return false
        default:
            return true
        }
    }

    /// Drop an LLVM `.<digits>` suffix (only when the name ends in a digit).
    private static func stripSuffix(_ name: String) -> String {
        guard let last = name.last, ("0" ... "9").contains(last) else { return name }
        if let dot = name.firstIndex(of: ".") {
            return String(name[name.startIndex ..< dot])
        }
        return name
    }

    /// Drop a `TQ<index>` / `TY<index>` async-continuation suffix.
    private static func stripAsyncContinuation(_ name: String) -> String {
        guard name.hasSuffix("_") else { return name }
        var stripped = Substring(name).dropLast()
        while let last = stripped.last, ("0" ... "9").contains(last) {
            stripped = stripped.dropLast()
        }
        if stripped.hasSuffix("TQ") || stripped.hasSuffix("TY") {
            return String(stripped.dropLast(2))
        }
        return name
    }
}
