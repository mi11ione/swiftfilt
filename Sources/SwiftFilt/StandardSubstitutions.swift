// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

/// The standard-library type substitutions (`S<x>` first level, `Sc<x>`
/// concurrency second level), generated from apple/swift's
/// `include/swift/Demangling/StandardTypesMangling.def`. Used by the parser
/// (`S`-prefixed substitution → node) and the remangler / printer (nominal
/// node → `S<x>` substitution).
enum StandardSubstitutions {
    struct Entry: Sendable {
        let kind: SwiftSymbol.Kind
        let mangling: Character
        let typeName: String
        let concurrency: Bool
    }

    /// All entries in `.def` order.
    static let all: [Entry] = [
        Entry(kind: .Structure, mangling: "A", typeName: "AutoreleasingUnsafeMutablePointer", concurrency: false),
        Entry(kind: .Structure, mangling: "a", typeName: "Array", concurrency: false),
        Entry(kind: .Structure, mangling: "b", typeName: "Bool", concurrency: false),
        Entry(kind: .Structure, mangling: "D", typeName: "Dictionary", concurrency: false),
        Entry(kind: .Structure, mangling: "d", typeName: "Double", concurrency: false),
        Entry(kind: .Structure, mangling: "f", typeName: "Float", concurrency: false),
        Entry(kind: .Structure, mangling: "h", typeName: "Set", concurrency: false),
        Entry(kind: .Structure, mangling: "I", typeName: "DefaultIndices", concurrency: false),
        Entry(kind: .Structure, mangling: "i", typeName: "Int", concurrency: false),
        Entry(kind: .Structure, mangling: "J", typeName: "Character", concurrency: false),
        Entry(kind: .Structure, mangling: "N", typeName: "ClosedRange", concurrency: false),
        Entry(kind: .Structure, mangling: "n", typeName: "Range", concurrency: false),
        Entry(kind: .Structure, mangling: "O", typeName: "ObjectIdentifier", concurrency: false),
        Entry(kind: .Structure, mangling: "P", typeName: "UnsafePointer", concurrency: false),
        Entry(kind: .Structure, mangling: "p", typeName: "UnsafeMutablePointer", concurrency: false),
        Entry(kind: .Structure, mangling: "R", typeName: "UnsafeBufferPointer", concurrency: false),
        Entry(kind: .Structure, mangling: "r", typeName: "UnsafeMutableBufferPointer", concurrency: false),
        Entry(kind: .Structure, mangling: "S", typeName: "String", concurrency: false),
        Entry(kind: .Structure, mangling: "s", typeName: "Substring", concurrency: false),
        Entry(kind: .Structure, mangling: "u", typeName: "UInt", concurrency: false),
        Entry(kind: .Structure, mangling: "V", typeName: "UnsafeRawPointer", concurrency: false),
        Entry(kind: .Structure, mangling: "v", typeName: "UnsafeMutableRawPointer", concurrency: false),
        Entry(kind: .Structure, mangling: "W", typeName: "UnsafeRawBufferPointer", concurrency: false),
        Entry(kind: .Structure, mangling: "w", typeName: "UnsafeMutableRawBufferPointer", concurrency: false),
        Entry(kind: .Enum, mangling: "q", typeName: "Optional", concurrency: false),
        Entry(kind: .protocolNode, mangling: "B", typeName: "BinaryFloatingPoint", concurrency: false),
        Entry(kind: .protocolNode, mangling: "E", typeName: "Encodable", concurrency: false),
        Entry(kind: .protocolNode, mangling: "e", typeName: "Decodable", concurrency: false),
        Entry(kind: .protocolNode, mangling: "F", typeName: "FloatingPoint", concurrency: false),
        Entry(kind: .protocolNode, mangling: "G", typeName: "RandomNumberGenerator", concurrency: false),
        Entry(kind: .protocolNode, mangling: "H", typeName: "Hashable", concurrency: false),
        Entry(kind: .protocolNode, mangling: "j", typeName: "Numeric", concurrency: false),
        Entry(kind: .protocolNode, mangling: "K", typeName: "BidirectionalCollection", concurrency: false),
        Entry(kind: .protocolNode, mangling: "k", typeName: "RandomAccessCollection", concurrency: false),
        Entry(kind: .protocolNode, mangling: "L", typeName: "Comparable", concurrency: false),
        Entry(kind: .protocolNode, mangling: "l", typeName: "Collection", concurrency: false),
        Entry(kind: .protocolNode, mangling: "M", typeName: "MutableCollection", concurrency: false),
        Entry(kind: .protocolNode, mangling: "m", typeName: "RangeReplaceableCollection", concurrency: false),
        Entry(kind: .protocolNode, mangling: "Q", typeName: "Equatable", concurrency: false),
        Entry(kind: .protocolNode, mangling: "T", typeName: "Sequence", concurrency: false),
        Entry(kind: .protocolNode, mangling: "t", typeName: "IteratorProtocol", concurrency: false),
        Entry(kind: .protocolNode, mangling: "U", typeName: "UnsignedInteger", concurrency: false),
        Entry(kind: .protocolNode, mangling: "X", typeName: "RangeExpression", concurrency: false),
        Entry(kind: .protocolNode, mangling: "x", typeName: "Strideable", concurrency: false),
        Entry(kind: .protocolNode, mangling: "Y", typeName: "RawRepresentable", concurrency: false),
        Entry(kind: .protocolNode, mangling: "y", typeName: "StringProtocol", concurrency: false),
        Entry(kind: .protocolNode, mangling: "Z", typeName: "SignedInteger", concurrency: false),
        Entry(kind: .protocolNode, mangling: "z", typeName: "BinaryInteger", concurrency: false),
        Entry(kind: .protocolNode, mangling: "A", typeName: "Actor", concurrency: true),
        Entry(kind: .Structure, mangling: "C", typeName: "CheckedContinuation", concurrency: true),
        Entry(kind: .Structure, mangling: "c", typeName: "UnsafeContinuation", concurrency: true),
        Entry(kind: .Structure, mangling: "E", typeName: "CancellationError", concurrency: true),
        Entry(kind: .Structure, mangling: "e", typeName: "UnownedSerialExecutor", concurrency: true),
        Entry(kind: .protocolNode, mangling: "F", typeName: "Executor", concurrency: true),
        Entry(kind: .protocolNode, mangling: "f", typeName: "SerialExecutor", concurrency: true),
        Entry(kind: .Structure, mangling: "G", typeName: "TaskGroup", concurrency: true),
        Entry(kind: .Structure, mangling: "g", typeName: "ThrowingTaskGroup", concurrency: true),
        Entry(kind: .protocolNode, mangling: "h", typeName: "TaskExecutor", concurrency: true),
        Entry(kind: .protocolNode, mangling: "I", typeName: "AsyncIteratorProtocol", concurrency: true),
        Entry(kind: .protocolNode, mangling: "i", typeName: "AsyncSequence", concurrency: true),
        Entry(kind: .Structure, mangling: "J", typeName: "UnownedJob", concurrency: true),
        Entry(kind: .Class, mangling: "M", typeName: "MainActor", concurrency: true),
        Entry(kind: .Structure, mangling: "P", typeName: "TaskPriority", concurrency: true),
        Entry(kind: .Structure, mangling: "S", typeName: "AsyncStream", concurrency: true),
        Entry(kind: .Structure, mangling: "s", typeName: "AsyncThrowingStream", concurrency: true),
        Entry(kind: .Structure, mangling: "T", typeName: "Task", concurrency: true),
        Entry(kind: .Structure, mangling: "t", typeName: "UnsafeCurrentTask", concurrency: true),
    ]

    /// A `Type(kind(Module("Swift"), Identifier(name)))` node — apple/swift's
    /// `createSwiftType`. Generic over the builder so the parser gets it as a
    /// `B.Node`; the remangler consumes only the `(mangling, secondLevel)`
    /// table below, so no `SwiftSymbol`-shaped overload is needed.
    static func swiftType<B: NodeBuilder>(kind: SwiftSymbol.Kind, name: String, _ nb: B) -> B.Node {
        nb.make(kind: .`Type`, child: nb.make(kind: kind, children: [
            nb.make(kind: .Module, name: SwiftManglingConstants.stdlibName),
            nb.make(kind: .Identifier, name: name),
        ]))
    }

    /// The node for a standard substitution `S<subst>` (or `Sc<subst>` when
    /// `secondLevel`), or `nil` when no entry matches — apple/swift's
    /// `createStandardSubstitution`.
    ///
    /// A switch on the mangling BYTE rather than a scan of ``all``. The scan
    /// compared `Character` to `Character` down a 67-entry list for every
    /// `S<x>` — one of the most common productions in the grammar — and
    /// grapheme comparison is not cheap; for a closed set of single ASCII bytes
    /// a jump table settles it in one step. The switches are generated from
    /// ``all``, and `StandardSubstitutionTableTests` asserts the two agree for
    /// every entry and for every byte outside the set, so they cannot drift.
    /// Takes the mangling BYTE, not a `Character`: the parser reads one byte
    /// off the cursor, and wrapping it in a `Character` only to compare
    /// graphemes was pure round-trip. Every mangling in the table is a single
    /// ASCII byte, so a non-ASCII byte matched nothing before and falls to the
    /// `default` arm now — the same `nil`.
    static func node<B: NodeBuilder>(forSubstitution byte: UInt8, secondLevel: Bool, _ nb: B) -> B.Node? {
        guard let entry = secondLevel ? secondLevelEntry(byte) : firstLevelEntry(byte) else { return nil }
        return swiftType(kind: entry.kind, name: entry.name, nb)
    }

    private static func firstLevelEntry(_ byte: UInt8) -> (kind: SwiftSymbol.Kind, name: String)? {
        switch byte {
        case 0x41: (.Structure, "AutoreleasingUnsafeMutablePointer") // A
        case 0x61: (.Structure, "Array") // a
        case 0x62: (.Structure, "Bool") // b
        case 0x44: (.Structure, "Dictionary") // D
        case 0x64: (.Structure, "Double") // d
        case 0x66: (.Structure, "Float") // f
        case 0x68: (.Structure, "Set") // h
        case 0x49: (.Structure, "DefaultIndices") // I
        case 0x69: (.Structure, "Int") // i
        case 0x4A: (.Structure, "Character") // J
        case 0x4E: (.Structure, "ClosedRange") // N
        case 0x6E: (.Structure, "Range") // n
        case 0x4F: (.Structure, "ObjectIdentifier") // O
        case 0x50: (.Structure, "UnsafePointer") // P
        case 0x70: (.Structure, "UnsafeMutablePointer") // p
        case 0x52: (.Structure, "UnsafeBufferPointer") // R
        case 0x72: (.Structure, "UnsafeMutableBufferPointer") // r
        case 0x53: (.Structure, "String") // S
        case 0x73: (.Structure, "Substring") // s
        case 0x75: (.Structure, "UInt") // u
        case 0x56: (.Structure, "UnsafeRawPointer") // V
        case 0x76: (.Structure, "UnsafeMutableRawPointer") // v
        case 0x57: (.Structure, "UnsafeRawBufferPointer") // W
        case 0x77: (.Structure, "UnsafeMutableRawBufferPointer") // w
        case 0x71: (.Enum, "Optional") // q
        case 0x42: (.protocolNode, "BinaryFloatingPoint") // B
        case 0x45: (.protocolNode, "Encodable") // E
        case 0x65: (.protocolNode, "Decodable") // e
        case 0x46: (.protocolNode, "FloatingPoint") // F
        case 0x47: (.protocolNode, "RandomNumberGenerator") // G
        case 0x48: (.protocolNode, "Hashable") // H
        case 0x6A: (.protocolNode, "Numeric") // j
        case 0x4B: (.protocolNode, "BidirectionalCollection") // K
        case 0x6B: (.protocolNode, "RandomAccessCollection") // k
        case 0x4C: (.protocolNode, "Comparable") // L
        case 0x6C: (.protocolNode, "Collection") // l
        case 0x4D: (.protocolNode, "MutableCollection") // M
        case 0x6D: (.protocolNode, "RangeReplaceableCollection") // m
        case 0x51: (.protocolNode, "Equatable") // Q
        case 0x54: (.protocolNode, "Sequence") // T
        case 0x74: (.protocolNode, "IteratorProtocol") // t
        case 0x55: (.protocolNode, "UnsignedInteger") // U
        case 0x58: (.protocolNode, "RangeExpression") // X
        case 0x78: (.protocolNode, "Strideable") // x
        case 0x59: (.protocolNode, "RawRepresentable") // Y
        case 0x79: (.protocolNode, "StringProtocol") // y
        case 0x5A: (.protocolNode, "SignedInteger") // Z
        case 0x7A: (.protocolNode, "BinaryInteger") // z
        default: nil
        }
    }

    private static func secondLevelEntry(_ byte: UInt8) -> (kind: SwiftSymbol.Kind, name: String)? {
        switch byte {
        case 0x41: (.protocolNode, "Actor") // A
        case 0x43: (.Structure, "CheckedContinuation") // C
        case 0x63: (.Structure, "UnsafeContinuation") // c
        case 0x45: (.Structure, "CancellationError") // E
        case 0x65: (.Structure, "UnownedSerialExecutor") // e
        case 0x46: (.protocolNode, "Executor") // F
        case 0x66: (.protocolNode, "SerialExecutor") // f
        case 0x47: (.Structure, "TaskGroup") // G
        case 0x67: (.Structure, "ThrowingTaskGroup") // g
        case 0x68: (.protocolNode, "TaskExecutor") // h
        case 0x49: (.protocolNode, "AsyncIteratorProtocol") // I
        case 0x69: (.protocolNode, "AsyncSequence") // i
        case 0x4A: (.Structure, "UnownedJob") // J
        case 0x4D: (.Class, "MainActor") // M
        case 0x50: (.Structure, "TaskPriority") // P
        case 0x53: (.Structure, "AsyncStream") // S
        case 0x73: (.Structure, "AsyncThrowingStream") // s
        case 0x54: (.Structure, "Task") // T
        case 0x74: (.Structure, "UnsafeCurrentTask") // t
        default: nil
        }
    }

    /// The `(mangling, secondLevel)` for a stdlib-rooted nominal type, or
    /// `nil` when it is not a standard substitution — drives the remangler's
    /// `mangleStandardSubstitution`.
    ///
    /// A dictionary, not a scan: the remangler asks this for every nominal node
    /// it mangles, and the scan compared `String` typeNames down the same
    /// 67-entry list. `(kind, typeName)` is unique across ``all`` — the table is
    /// apple/swift's `StandardTypesMangling.def`, one entry per stdlib type —
    /// so the map holds exactly 67 pairs and answers what the first-match scan
    /// answered.
    private static let byType: [TypeKey: (mangling: Character, secondLevel: Bool)] = {
        var map: [TypeKey: (mangling: Character, secondLevel: Bool)] = [:]
        map.reserveCapacity(all.count)
        for entry in all {
            map[TypeKey(kind: entry.kind, typeName: entry.typeName)] = (entry.mangling, entry.concurrency)
        }
        return map
    }()

    struct TypeKey: Hashable {
        let kind: SwiftSymbol.Kind
        let typeName: String
    }

    static func substitution(forKind kind: SwiftSymbol.Kind, typeName: String) -> (mangling: Character, secondLevel: Bool)? {
        byType[TypeKey(kind: kind, typeName: typeName)]
    }
}
