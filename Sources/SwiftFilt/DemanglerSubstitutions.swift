// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// Substitution decoding, identifier decoding, and context popping for the
// current-mangling `Demangler` — ported from `lib/Demangling/Demangler.cpp`.

extension Demangler {
    mutating func demangleMultiSubstitutions() -> B.Node? {
        var repeatCount = -1
        while true {
            let c = nextChar()
            if c == 0 { return nil }
            if ManglingChars.isLowerLetter(c) {
                guard let node = pushMultiSubstitutions(repeatCount: repeatCount, index: Int(c - 0x61)) else {
                    return nil
                }
                pushNode(node)
                repeatCount = -1
                continue
            }
            if ManglingChars.isUpperLetter(c) {
                return pushMultiSubstitutions(repeatCount: repeatCount, index: Int(c - 0x41))
            }
            if c == 0x5F { // '_': large index = repeatCount + 27
                let idx = repeatCount + 27
                guard idx >= 0, idx < stacks.subsCount else { return nil }
                return stacks.sub(at: idx)
            }
            pushBack()
            repeatCount = demangleNatural()
            if repeatCount < 0 { return nil }
        }
    }

    mutating func pushMultiSubstitutions(repeatCount: Int, index: Int) -> B.Node? {
        guard index >= 0, index < stacks.subsCount else { return nil }
        if repeatCount > SwiftManglingConstants.maxRepeatCount { return nil }
        let node = stacks.sub(at: index)
        var remaining = repeatCount
        while remaining > 1 {
            pushNode(node)
            remaining -= 1
        }
        return node
    }

    mutating func demangleStandardSubstitution() -> B.Node? {
        switch nextChar() {
        case 0x6F: // 'o'
            return nb.make(kind: .Module, name: SwiftManglingConstants.objCModule)
        case 0x43: // 'C'
            return nb.make(kind: .Module, name: SwiftManglingConstants.clangImporterModule)
        case 0x67: // 'g'
            guard let inner = popNode(.`Type`),
                  let optional = createType(nb.make(kind: .BoundGenericEnum, children: [
                      StandardSubstitutions.swiftType(kind: .Enum, name: "Optional", nb),
                      nb.make(kind: .TypeList, child: inner),
                  ]))
            else { return nil }
            addSubstitution(optional)
            return optional
        default:
            pushBack()
            let repeatCount = demangleNatural()
            if repeatCount > SwiftManglingConstants.maxRepeatCount { return nil }
            let secondLevel = nextIf(0x63) // 'c'
            guard let node = StandardSubstitutions.node(forSubstitution: Character(UnicodeScalar(nextChar())), secondLevel: secondLevel, nb) else {
                return nil
            }
            var remaining = repeatCount
            while remaining > 1 {
                pushNode(node)
                remaining -= 1
            }
            return node
        }
    }

    mutating func demangleIdentifier() -> B.Node? {
        let c = peekChar()
        if !ManglingChars.isDigit(c) { return nil }

        // Fast path: a plain length-prefixed identifier — first char a
        // non-zero digit, so no leading-'0' word-substitution or punycode marker —
        // is a SINGLE verbatim slice of the input. A leading '0' instead selects
        // word substitutions (assembled from pieces) or, with a second '0',
        // punycode (Unicode-decoded); both are handled by the general path below
        // and produce owned text. Here the identifier body IS `text[sliceStart ..<
        // sliceEnd]` with no accumulator and no transform, so tag it as an input
        // range (rendered zero-copy on the arena backend) — but only when the slice
        // is pure ASCII: `String(decoding:as:UTF8)` is lossy on ill-formed UTF-8
        // (a stray non-ASCII byte appears only in malformed input; a well-formed
        // non-ASCII identifier is punycoded), so a non-ASCII slice falls back to
        // the owned decode to stay byte-identical to the value backend.
        if c != 0x30 {
            let numChars = demangleNatural()
            if numChars <= 0 { return nil }
            guard pos + numChars <= textEnd else { return nil }
            let sliceStart = pos
            let sliceEnd = pos + numChars
            let isASCII = harvestWords(from: sliceStart, to: sliceEnd)
            pos += numChars
            let node: B.Node = isASCII
                ? nb.makeIdentifier(text, start: sliceStart, count: numChars)
                : nb.make(kind: .Identifier, name: String(decoding: text[sliceStart ..< sliceEnd], as: UTF8.self))
            addSubstitution(node)
            return node
        }

        // General path (owned text): leading '0' — word substitutions and/or
        // punycode. The result is assembled or transformed, never a verbatim input
        // slice, so it is built into an accumulator and interned as owned text.
        var hasWordSubsts = false
        var isPunycoded = false
        pos += 1
        if peekChar() == 0x30 {
            pos += 1
            isPunycoded = true
        } else {
            hasWordSubsts = true
        }
        var identifier: [UInt8] = []
        repeat {
            while hasWordSubsts, ManglingChars.isLetter(peekChar()) {
                let ch = nextChar()
                let wordIndex: Int
                if ManglingChars.isLowerLetter(ch) {
                    wordIndex = Int(ch - 0x61)
                } else {
                    wordIndex = Int(ch - 0x41)
                    hasWordSubsts = false
                }
                guard wordIndex < stacks.wordsCount else { return nil }
                identifier.append(contentsOf: text[stacks.word(at: wordIndex)])
            }
            if nextIf(0x30) { break } // '0'
            let numChars = demangleNatural()
            if numChars <= 0 { return nil }
            if isPunycoded { _ = nextIf(0x5F) } // optional '_'
            guard pos + numChars <= textEnd else { return nil }
            // The identifier body is consumed as a slice of `text` in
            // place — no per-identifier copy; harvested words are ranges
            // into `text` (see `words`), mirroring the reference's
            // StringRef words. Indices below are absolute.
            let sliceStart = pos
            let sliceEnd = pos + numChars
            if isPunycoded {
                guard let decoded = SwiftPunycode.decodeToString(Array(text[sliceStart ..< sliceEnd])) else { return nil }
                identifier.append(contentsOf: decoded.utf8)
            } else {
                identifier.append(contentsOf: text[sliceStart ..< sliceEnd])
                harvestWords(from: sliceStart, to: sliceEnd)
            }
            pos += numChars
        } while hasWordSubsts

        if identifier.isEmpty {
            return nil
        }
        // Assembled (owned) text: the arena pools these bytes with no
        // `String`; the value backend decodes exactly the `String` this
        // site used to build.
        let node = nb.make(kind: .Identifier, ownedBytes: identifier)
        addSubstitution(node)
        return node
    }

    /// Harvest substitution words from the identifier body `text[start ..< end]`
    /// into the stacks' word region (max ``SwiftManglingConstants/maxNumWords``,
    /// min length 2) —
    /// the reference demangler's word-boundary scan, so a later identifier can
    /// back-reference these ranges. Word ranges are into `text`, mirroring the
    /// reference's `StringRef` words. Shared verbatim by the verbatim fast path
    /// and the word-substitution/general path so both harvest identically.
    ///
    /// Returns whether the body is pure ASCII, folded into the same pass —
    /// the fast path needs both answers, and `demangleIdentifier` is the
    /// stream profile's largest self-cost site: one walk over the bytes
    /// through an unchecked buffer view (the array subscripts' bounds checks
    /// framed here), with the previous byte carried in a register instead of
    /// re-read. Word semantics are byte-for-byte the two-pass original's:
    /// `prev` equals `text[idx-1]` wherever the original read it (a word-end
    /// probe can only fire past the first byte), and the ASCII test covers
    /// exactly `[start, end)` (the terminator pseudo-byte is 0).
    @inline(__always)
    @discardableResult
    private mutating func harvestWords(from start: Int, to end: Int) -> Bool {
        text.withUnsafeBufferPointer { buffer in
            var isASCII = true
            var wordStart = -1
            var prev: UInt8 = 0
            var idx = start
            while idx <= end {
                let ch: UInt8 = idx < end ? buffer[idx] : 0
                if ch >= 0x80 { isASCII = false }
                if wordStart >= 0, ManglingChars.isWordEnd(ch, prev: prev) {
                    if idx - wordStart >= 2, stacks.wordsCount < SwiftManglingConstants.maxNumWords {
                        stacks.appendWord(wordStart ..< idx)
                    }
                    wordStart = -1
                }
                if wordStart < 0, ManglingChars.isWordStart(ch) {
                    wordStart = idx
                }
                prev = ch
                idx += 1
            }
            return isASCII
        }
    }

    mutating func demangleOperatorIdentifier() -> B.Node? {
        guard let ident = popNode(.Identifier), let text = nb.text(of: ident) else { return nil }
        // Reverse table: index = letter - 'a'; ' ' marks invalid.
        let opCharTable = Array("& @/= >    <*!|+?%-~   ^ .".utf8)
        var opStr: [UInt8] = []
        for byte in text.utf8 {
            if byte >= 0x80 {
                opStr.append(byte) // pass through Unicode
                continue
            }
            if !ManglingChars.isLowerLetter(byte) { return nil }
            let translated = opCharTable[Int(byte - 0x61)]
            if translated == 0x20 { return nil } // ' '
            opStr.append(translated)
        }
        switch nextChar() {
        case 0x69: return nb.make(kind: .InfixOperator, ownedBytes: opStr) // 'i'
        case 0x70: return nb.make(kind: .PrefixOperator, ownedBytes: opStr) // 'p'
        case 0x50: return nb.make(kind: .PostfixOperator, ownedBytes: opStr) // 'P'
        default: return nil
        }
    }

    mutating func demangleLocalIdentifier() -> B.Node? {
        if nextIf(0x4C) { // 'L'
            let discriminator = popNode(.Identifier)
            let name = popNode(DemanglerPredicates.isDeclName)
            return createWithChildren(.PrivateDeclName, discriminator, name)
        }
        if nextIf(0x6C) { // 'l'
            let discriminator = popNode(.Identifier)
            return createWithChild(.PrivateDeclName, discriminator)
        }
        let p = peekChar()
        if (p >= 0x61 && p <= 0x6A) || (p >= 0x41 && p <= 0x4A) { // 'a'..'j' / 'A'..'J'
            let relatedKind = nextChar()
            let kindNode = nb.make(kind: .Identifier, name: String(UnicodeScalar(relatedKind)))
            let name = popNode()
            var result = nb.make(kind: .RelatedEntityDeclName, child: kindNode)
            if let name { nb.appendChild(to: &result, name) }
            return result
        }
        let discriminator = demangleIndexAsNode()
        let name = popNode(DemanglerPredicates.isDeclName)
        return createWithChildren(.LocalDeclName, discriminator, name)
    }

    // MARK: Context popping

    mutating func popModule() -> B.Node? {
        if let ident = popNode(.Identifier) {
            return nb.changingKind(ident, to: .Module)
        }
        return popNode(.Module)
    }

    mutating func popContext() -> B.Node? {
        if let module = popModule() { return module }
        if let type = popNode(.`Type`) {
            guard nb.childCount(of: type) == 1, let child = nb.firstChild(of: type),
                  DemanglerPredicates.isContext(nb.kind(of: child))
            else { return nil }
            return child
        }
        return popNode(DemanglerPredicates.isContext)
    }

    mutating func popTypeAndGetChild() -> B.Node? {
        guard let type = popNode(.`Type`), nb.childCount(of: type) == 1 else { return nil }
        return nb.firstChild(of: type)
    }

    mutating func popTypeAndGetAnyGeneric() -> B.Node? {
        guard let child = popTypeAndGetChild(), DemanglerPredicates.isAnyGeneric(nb.kind(of: child)) else { return nil }
        return child
    }
}
