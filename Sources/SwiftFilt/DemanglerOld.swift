// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// Bridge from the current-mangling ``Demangler`` to the legacy `_T` parser in
// ``OldDemangler``.

extension Demangler {
    /// Demangle a legacy `_T` symbol. The full text (including its `_T`
    /// prefix) is handed to ``OldDemangler``, which re-consumes the prefix
    /// itself — `demangleSymbol()` routes here on a `_T` prefix that is not the
    /// Swift-4.0 `_T0` new-mangling prefix.
    mutating func demangleOldSymbolAsNode() -> B.Node? {
        // ``OldDemangler`` stays on the concrete ``SwiftSymbol`` (out of scope
        // for the builder abstraction); adopt its tree into the builder's node
        // space at this bridge. The window bounds carry through: a scanner
        // candidate parses `text[textStart ..< textEnd]` exactly as a
        // whole-buffer parse of those bytes would.
        OldDemangler(text: text, position: textStart, end: textEnd).demangleTopLevelOld().map { nb.adopt($0) }
    }
}
