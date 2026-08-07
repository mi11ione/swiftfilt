// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

/// Re-mangles a ``SwiftSymbol`` tree back to its mangled string, the inverse
/// of ``SwiftDemangler``. A faithful port of apple/swift's
/// `lib/Demangling/Remangler.cpp`. Substitutions are re-established in the same
/// insertion order the demangler assigns, so a demangle→mangle round-trip is
/// byte-identical (the self-consistency bar).
@frozen
public struct SwiftMangler: Sendable {
    public init() {}

    /// The mangled string for `symbol`, or `nil` when the tree cannot be
    /// mangled (an unsupported or malformed node shape).
    public func mangle(_ symbol: SwiftSymbol) -> String? {
        let remangler = Remangler()
        // One up-front reservation sized for the common mangling, so the
        // typical mangle never regrows the output (a fresh empty buffer's
        // geometric growth billed several allocations per mangle on the
        // remangle-heavy paths: identity keys, round-trips, the
        // opaque-parenting parent-ID). Pure capacity — no byte differs.
        remangler.buffer.reserveCapacity(128)
        guard remangler.mangle(symbol, depth: 0) else { return nil }
        return String(decoding: remangler.buffer, as: UTF8.self)
    }
}

/// The mutable re-mangling state and algorithm. Reference type because the
/// mangle is stateful (an output buffer, a substitution table, word state).
/// Methods return `Bool` (`true` = success); a `false` propagates up as a
/// failed mangle (the `nil` boundary of ``SwiftMangler/mangle(_:)``).
final class Remangler {
    /// `@exclusivity(unchecked)` on the stored state: class-property mutations
    /// otherwise pay a dynamic `swift_beginAccess` pair per emit/append (the
    /// constant-prop round-trip made this visible on the demangle-complex
    /// profile). Sound as in ``Demangler``: single-threaded, non-reentrant, no
    /// overlapping formal access to any one property (`merging` and `buffer`
    /// are distinct properties; `tryMergeSubst` mutates `merging` while
    /// touching only `buffer`).
    @exclusivity(unchecked) var buffer: [UInt8] = []
    /// Number of substitutions assigned so far; the next one's index.
    @exclusivity(unchecked) private var substitutionCount = 0
    /// O(1) substitution lookup (the apple/swift reference uses an inline-16 +
    /// overflow hash map with a precomputed `deepHash` per entry for the same
    /// reason). Keyed by the equality basis: structural-node entries by the
    /// node itself, identifier entries by their operator-translated text. The
    /// first-assigned index wins (matching a first-match linear scan), though
    /// `addSubstitution` is only reached for content not already substituted,
    /// so duplicates do not arise. The node key wraps the symbol with a
    /// structural FNV digest (``SubstitutionEntry``) so the table's hashing
    /// is one tight byte-walk instead of `Hasher` visiting every subtree node
    /// — equality (and therefore every substitution DECISION) is still the
    /// full structural `==`, exactly the reference's `deepEquals` backstop.
    @exclusivity(unchecked) private var nodeSubstitutionIndex: [SubstitutionEntry: Int] = [:]
    @exclusivity(unchecked) private var identifierSubstitutionIndex: [String: Int] = [:]
    /// Word slices already emitted into `buffer` (start, length), for the
    /// identifier word-substitution encoder.
    @exclusivity(unchecked) var words: [(start: Int, length: Int)] = []
    @exclusivity(unchecked) var substWordsInIdent: [(stringPos: Int, wordIndex: Int)] = []
    @exclusivity(unchecked) var flavor: SwiftManglingFlavor = .standard
    @exclusivity(unchecked) private var merging = SubstitutionMerging()

    static let maxDepth = SwiftManglingConstants.maxDepth
    static let maxNumWords = SwiftManglingConstants.maxNumWords

    // MARK: Output helpers

    @inline(__always) func emit(_ c: UInt8) {
        buffer.append(c)
    }

    /// Append a COMPILE-TIME-CONSTANT fragment — a `StaticString` is a pointer
    /// and a length, so this is a bounds check and a memcpy, where the `String`
    /// overload runs `String.UTF8View`'s `Sequence` conformance through
    /// `_StringGuts.copyUTF8`. The same overload split the printer uses:
    /// an uninterpolated literal binds here, anything else to ``emitDynamic``.
    @inline(__always) func emit(_ s: StaticString) {
        s.withUTF8Buffer { buffer.append(contentsOf: $0) }
    }

    @inline(__always) func emitDynamic(_ s: String) {
        buffer.append(contentsOf: s.utf8)
    }

    @inline(__always) func emit(_ s: [UInt8]) {
        buffer.append(contentsOf: s)
    }

    @inline(__always) func resetBuffer(to size: Int) {
        buffer.removeLast(buffer.count - size)
    }

    /// `_` for 0, otherwise `(value-1)_` (apple/swift's `mangleIndex`).
    func mangleIndex(_ value: UInt64) {
        if value == 0 {
            emit(UInt8(0x5F)) // '_'
        } else {
            emitDynamic(String(value - 1))
            emit(UInt8(0x5F))
        }
    }

    // MARK: Child helpers

    func skipType(_ node: SwiftSymbol) -> SwiftSymbol {
        node.kind == .`Type` ? (node.firstChild ?? node) : node
    }

    func mangleChildNodes(_ node: SwiftSymbol, depth: Int) -> Bool {
        for child in node.children where !mangle(child, depth: depth) {
            return false
        }
        return true
    }

    func mangleChildNodesReversed(_ node: SwiftSymbol, depth: Int) -> Bool {
        for child in node.children.reversed() where !mangle(child, depth: depth) {
            return false
        }
        return true
    }

    func mangleChildNode(_ node: SwiftSymbol, _ index: Int, depth: Int) -> Bool {
        guard index < node.children.count else { return true }
        return mangle(node.children[index], depth: depth)
    }

    func mangleSingleChildNode(_ node: SwiftSymbol, depth: Int) -> Bool {
        guard node.children.count == 1 else { return false }
        return mangle(node.children[0], depth: depth)
    }

    func mangleListSeparator(_ isFirst: inout Bool) {
        if isFirst { emit(UInt8(0x5F)); isFirst = false } // '_'
    }

    func mangleEndOfList(_ isFirst: Bool) {
        if isFirst { emit(UInt8(0x79)) } // 'y'
    }

    // MARK: Substitutions

    /// The identifier substitution table's key.
    ///
    /// Keyed as a `String`, so the common (non-operator) case IS the node's own
    /// payload and allocates nothing — the former `[UInt8]` key built
    /// `Array(text.utf8)` on every probe and every insert, and this table is
    /// consulted for every identifier the remangler emits. The two keyings
    /// distinguish exactly the same identifiers: `translateOperatorChar` maps a
    /// standalone ASCII byte to another ASCII byte and passes every other byte
    /// through, so on the valid UTF-8 a `String` payload always is, byte-wise
    /// translation yields valid UTF-8 (no mapped byte is a continuation byte,
    /// and none is produced from one) and the decode is lossless — equal keys
    /// before are equal keys after.
    private func identifierKey(_ node: SwiftSymbol) -> String {
        let text = node.text ?? ""
        switch node.kind {
        case .InfixOperator, .PrefixOperator, .PostfixOperator:
            return String(decoding: ManglingChars.translateOperator(Array(text.utf8)), as: UTF8.self)
        default:
            return text
        }
    }

    /// A substitution-table key: the node plus its structural FNV-1a digest,
    /// mirroring the reference `SubstitutionEntry`'s node + `deepHash` pair.
    /// Hashing combines only the precomputed digest (one tight byte-walk at
    /// key construction — `Hasher` was walking every subtree node on every
    /// probe and insert, the demangle-complex profile's dictionary bucket);
    /// equality stays the full structural `==`, so a digest collision can
    /// slow a probe but never change a substitution decision.
    private struct SubstitutionEntry: Hashable {
        let node: SwiftSymbol
        let digest: UInt64

        init(_ node: SwiftSymbol) {
            self.node = node
            var h: UInt64 = 0xCBF2_9CE4_8422_2325
            Self.walk(node, into: &h)
            digest = h
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(digest)
        }

        @inline(__always)
        private static func mix(_ value: UInt64, into h: inout UInt64) {
            h = (h ^ value) &* 0x1_0000_0000_01B3
        }

        /// Deterministic structural walk: kind ordinal, payload, child count,
        /// children — enough to make digest-equal-but-unequal trees rare;
        /// correctness never depends on it (see `==`).
        private static func walk(_ node: SwiftSymbol, into h: inout UInt64) {
            withUnsafeBytes(of: node.kind) { raw in
                for byte in raw {
                    mix(UInt64(byte), into: &h)
                }
            }
            switch node.contents {
            case .none:
                mix(1, into: &h)
            case let .index(value):
                mix(2, into: &h)
                mix(value, into: &h)
            case let .name(value):
                mix(3, into: &h)
                for byte in value.utf8 {
                    mix(UInt64(byte), into: &h)
                }
            }
            mix(UInt64(truncatingIfNeeded: node.children.count), into: &h)
            for child in node.children {
                walk(child, into: &h)
            }
        }
    }

    private func findSubstitution(_ node: SwiftSymbol, treatAsIdentifier: Bool) -> Int? {
        treatAsIdentifier ? identifierSubstitutionIndex[identifierKey(node)] : nodeSubstitutionIndex[SubstitutionEntry(node)]
    }

    func addSubstitution(_ node: SwiftSymbol, treatAsIdentifier: Bool = false) {
        let idx = substitutionCount
        substitutionCount += 1
        // One hash and one probe, not two: the check-then-assign form asked
        // `== nil` and then assigned, and by the invariant recorded on the
        // tables above — `addSubstitution` is only reached for content not
        // already substituted — that check answered "absent" every time, so
        // first-assigned-wins and last-assigned-wins cannot differ here.
        if treatAsIdentifier {
            identifierSubstitutionIndex.updateValue(idx, forKey: identifierKey(node))
        } else {
            nodeSubstitutionIndex.updateValue(idx, forKey: SubstitutionEntry(node))
        }
    }

    /// Try to emit `node` as a back-reference substitution. Returns `true` if
    /// it was substituted (caller emits nothing more); `false` means the caller
    /// must mangle it fresh and then `addSubstitution`.
    func trySubstitution(_ node: SwiftSymbol, treatAsIdentifier: Bool = false) -> Bool {
        if mangleStandardSubstitution(node) { return true }
        guard let idx = findSubstitution(node, treatAsIdentifier: treatAsIdentifier) else { return false }
        if idx >= 26 {
            emit(UInt8(0x41)) // 'A'
            mangleIndex(UInt64(idx - 26))
            return true
        }
        let substChar: [UInt8] = [UInt8(0x41 + idx)] // 'A'+idx
        if !merging.tryMergeSubst(self, subst: substChar, isStandardSubst: false) {
            emit(UInt8(0x41)) // 'A'
            emit(substChar)
        }
        return true
    }

    /// Emit a stdlib type as a standard substitution (`S<x>`/`Sc<x>`). Returns
    /// `true` if `node` is a standard substitution.
    func mangleStandardSubstitution(_ node: SwiftSymbol) -> Bool {
        switch node.kind {
        case .Structure, .Class, .Enum, .protocolNode: break
        default: return false
        }
        guard let context = node.firstChild, context.kind == .Module,
              context.text == SwiftManglingConstants.stdlibName,
              node.children.count > 1, node.children[1].kind == .Identifier,
              let typeName = node.children[1].text,
              let subst = StandardSubstitutions.substitution(forKind: node.kind, typeName: typeName)
        else { return false }
        var bytes: [UInt8] = []
        if subst.secondLevel { bytes.append(UInt8(0x63)) } // 'c'
        bytes.append(subst.mangling.asciiValue ?? 0)
        if !merging.tryMergeSubst(self, subst: bytes, isStandardSubst: true) {
            emit(UInt8(0x53)) // 'S'
            emit(bytes)
        }
        return true
    }

    func mangleIdentifierImpl(_ node: SwiftSymbol, isOperator: Bool) {
        if trySubstitution(node, treatAsIdentifier: true) { return }
        let text = Array((node.text ?? "").utf8)
        let ident = isOperator ? ManglingChars.translateOperator(text) : text
        encodeIdentifier(ident)
        addSubstitution(node, treatAsIdentifier: true)
    }

    // MARK: Dispatch

    @_optimize(speed)
    func mangle(_ node: SwiftSymbol, depth: Int) -> Bool {
        if depth > Remangler.maxDepth { return false }
        return mangleNode(node, depth: depth)
    }
}

// MARK: - SubstitutionMerging

/// Collapses adjacent substitutions (`AB`→`A2B`/`AbC`, `S3i`→`S4i`) — a port
/// of apple/swift's `Mangle::SubstitutionMerging`.
private struct SubstitutionMerging {
    private var lastSubstPosition = 0
    private var lastSubstSize = 0
    private var lastNumSubsts = 0
    private var lastIsStandard = false
    private let maxRepeatCount = SwiftManglingConstants.maxRepeatCount

    /// Try to merge `subst` (the substitution chars, without the leading
    /// `A`/`S`) with the previous one. Returns `true` if merged (buffer
    /// mutated in place); `false` means the caller emits `A`/`S` + subst.
    mutating func tryMergeSubst(_ r: Remangler, subst: [UInt8], isStandardSubst: Bool) -> Bool {
        if lastNumSubsts > 0, lastNumSubsts < maxRepeatCount,
           r.buffer.count == lastSubstPosition + lastSubstSize,
           lastIsStandard == isStandardSubst
        {
            // The last mangled thing is a substitution.
            let lastSubst = Array(r.buffer[(r.buffer.count - lastSubstSize)...].drop { ManglingChars.isDigit($0) })
            if lastSubst != subst, !isStandardSubst {
                // Merge with a different 'A' substitution: 'AB' -> 'AbC'.
                lastSubstPosition = r.buffer.count
                lastNumSubsts = 1
                r.resetBuffer(to: r.buffer.count - 1)
                guard let lastChar = lastSubst.last else { return false }
                r.emit(UInt8(lastChar - 0x41 + 0x61)) // uppercase -> lowercase
                r.emit(subst)
                lastSubstSize = 1
                return true
            }
            if lastSubst == subst {
                // Merge with the same substitution: 'AB' -> 'A2B' / 'S3i' -> 'S4i'.
                lastNumSubsts += 1
                r.resetBuffer(to: lastSubstPosition)
                r.emitDynamic(String(lastNumSubsts))
                r.emit(subst)
                lastSubstSize = r.buffer.count - lastSubstPosition
                return true
            }
        }
        // Cannot merge; record this substitution for the next attempt.
        lastSubstPosition = r.buffer.count + 1
        lastSubstSize = subst.count
        lastNumSubsts = 1
        lastIsStandard = isStandardSubst
        return false
    }
}

// MARK: - Identifier word-substitution encoder

extension Remangler {
    /// Mangle `ident` (UTF-8 bytes) with word substitutions / punycode — a port
    /// of apple/swift's `Mangle::mangleIdentifier`.
    @_optimize(speed)
    func encodeIdentifier(_ ident: [UInt8]) {
        let wordsInBuffer = words.count
        substWordsInIdent.removeAll(keepingCapacity: true)

        if ManglingChars.needsPunycodeEncoding(ident),
           let punycoded = SwiftPunycode.encodeFromUTF8(ident, mapNonSymbolChars: true)
        {
            emit("00")
            emitDynamic(String(punycoded.count))
            if let first = punycoded.first, ManglingChars.isDigit(first) || first == 0x5F {
                emit(UInt8(0x5F)) // '_'
            }
            emit(punycoded)
            return
        }

        // Find word substitutions and new words.
        var wordStartPos = -1
        let len = ident.count
        var pos = 0
        while pos <= len {
            let ch: UInt8 = pos < len ? ident[pos] : 0
            if wordStartPos != -1, ManglingChars.isWordEnd(ch, prev: ident[pos - 1]) {
                let wordLen = pos - wordStartPos
                var wordIndex = lookupWord(ident, wordStartPos, wordLen, in: buffer, from: 0, to: wordsInBuffer)
                if wordIndex < 0 {
                    wordIndex = lookupWord(ident, wordStartPos, wordLen, in: ident, from: wordsInBuffer, to: words.count)
                }
                if wordIndex >= 0 {
                    substWordsInIdent.append((wordStartPos, wordIndex))
                } else if wordLen >= 2, words.count < Remangler.maxNumWords {
                    words.append((wordStartPos, wordLen))
                }
                wordStartPos = -1
            }
            if wordStartPos == -1, ManglingChars.isWordStart(ch) {
                wordStartPos = pos
            }
            pos += 1
        }

        if !substWordsInIdent.isEmpty { emit(UInt8(0x30)) } // '0'

        var cursor = 0
        var wordsInBufferIdx = wordsInBuffer
        substWordsInIdent.append((ident.count, -1)) // sentinel dummy-word
        let end = substWordsInIdent.count
        for idx in 0 ..< end {
            let repl = substWordsInIdent[idx]
            if cursor < repl.stringPos {
                emitDynamic(String(repl.stringPos - cursor))
                var first = true
                while cursor < repl.stringPos {
                    if wordsInBufferIdx < words.count, words[wordsInBufferIdx].start == cursor {
                        words[wordsInBufferIdx].start = buffer.count
                        wordsInBufferIdx += 1
                    }
                    if first, ManglingChars.isDigit(ident[cursor]) {
                        emit(UInt8(0x58)) // 'X' escapes a leading digit
                    } else {
                        emit(ident[cursor])
                    }
                    cursor += 1
                    first = false
                }
            }
            if repl.wordIndex >= 0 {
                cursor += words[repl.wordIndex].length
                if idx < end - 2 {
                    emit(UInt8(repl.wordIndex + 0x61)) // 'a'+idx (more follow)
                } else {
                    emit(UInt8(repl.wordIndex + 0x41)) // 'A'+idx (last)
                    if cursor == ident.count { emit(UInt8(0x30)) } // '0'
                }
            }
        }
        substWordsInIdent.removeAll(keepingCapacity: true)
    }

    /// Look up the word `ident[wordStart ..< wordStart+wordLength]` in the
    /// recorded word table. The candidate word is passed as base + range —
    /// materializing an `Array` per probe (one per word occurrence) put
    /// this lookup at the top of the remangle allocation profile
    /// (identityKey, round-trips, the opaque-parenting remangle). Byte
    /// comparison in place, length gate first: the equal-length gate
    /// rejects most candidates before any byte is read.
    private func lookupWord(_ ident: [UInt8], _ wordStart: Int, _ wordLength: Int, in source: [UInt8], from: Int, to: Int) -> Int {
        for idx in from ..< to {
            let w = words[idx]
            guard w.length == wordLength, w.start + w.length <= source.count else { continue }
            var matches = true
            for k in 0 ..< wordLength where source[w.start + k] != ident[wordStart + k] {
                matches = false
                break
            }
            if matches { return idx }
        }
        return -1
    }
}
