// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

/// Byte-level character predicates and operator translation shared by the
/// Swift demangler, remangler, and printer — a faithful port of apple/swift's
/// `include/swift/Demangling/ManglingUtils.h` / `ManglingUtils.cpp`.
///
/// The parser operates on UTF-8 bytes (`UInt8`) rather than Swift `Character`s
/// because the mangling grammar is byte-precise: lengths, operators, and
/// substitutions are ASCII while identifier bodies carry raw UTF-8 / Punycode
/// and symbolic references carry arbitrary bytes.
enum ManglingChars {
    @inline(__always) static func isLowerLetter(_ ch: UInt8) -> Bool {
        ch >= 0x61 && ch <= 0x7A
    }

    @inline(__always) static func isUpperLetter(_ ch: UInt8) -> Bool {
        ch >= 0x41 && ch <= 0x5A
    }

    @inline(__always) static func isDigit(_ ch: UInt8) -> Bool {
        ch >= 0x30 && ch <= 0x39
    }

    @inline(__always) static func isLetter(_ ch: UInt8) -> Bool {
        isLowerLetter(ch) || isUpperLetter(ch)
    }

    /// A character that begins a substitution word.
    @inline(__always)
    static func isWordStart(_ ch: UInt8) -> Bool {
        !isDigit(ch) && ch != 0x5F && ch != 0
    }

    /// A character (following `prevCh`) that ends a substitution word.
    @inline(__always)
    static func isWordEnd(_ ch: UInt8, prev prevCh: UInt8) -> Bool {
        if ch == 0x5F || ch == 0 { return true }
        if !isUpperLetter(prevCh), isUpperLetter(ch) { return true }
        return false
    }

    /// A valid first character of a symbol mangling.
    @inline(__always)
    static func isValidSymbolStart(_ ch: UInt8) -> Bool {
        isLetter(ch) || ch == 0x5F || ch == 0x24 // '_' or '$'
    }

    /// A valid non-first character of a symbol mangling.
    @inline(__always)
    static func isValidSymbolChar(_ ch: UInt8) -> Bool {
        isValidSymbolStart(ch) || isDigit(ch)
    }

    /// Whether `bytes` contains any byte that cannot appear literally in a
    /// mangled symbol and therefore must be Punycode-encoded.
    @_effects(readonly)
    static func needsPunycodeEncoding(_ bytes: [UInt8]) -> Bool {
        guard let first = bytes.first else { return false }
        if !isValidSymbolStart(first) { return true }
        for c in bytes.dropFirst() where !isValidSymbolChar(c) {
            return true
        }
        return false
    }

    /// Translate an operator character into its mangled letter (`+`→`p`,
    /// `<`→`l`, …); non-operator characters pass through unchanged.
    @_effects(readonly)
    static func translateOperatorChar(_ op: UInt8) -> UInt8 {
        switch op {
        case 0x26: 0x61 // & -> a
        case 0x40: 0x63 // @ -> c
        case 0x2F: 0x64 // / -> d
        case 0x3D: 0x65 // = -> e
        case 0x3E: 0x67 // > -> g
        case 0x3C: 0x6C // < -> l
        case 0x2A: 0x6D // * -> m
        case 0x21: 0x6E // ! -> n
        case 0x7C: 0x6F // | -> o
        case 0x2B: 0x70 // + -> p
        case 0x3F: 0x71 // ? -> q
        case 0x25: 0x72 // % -> r
        case 0x2D: 0x73 // - -> s
        case 0x7E: 0x74 // ~ -> t
        case 0x5E: 0x78 // ^ -> x
        case 0x2E: 0x7A // . -> z
        default: op
        }
    }

    /// Translate every character of operator `op` to its mangled form.
    @_effects(readonly)
    static func translateOperator(_ op: [UInt8]) -> [UInt8] {
        op.map(translateOperatorChar)
    }
}
