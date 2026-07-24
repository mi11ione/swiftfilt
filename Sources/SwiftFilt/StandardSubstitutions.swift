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
    static func node<B: NodeBuilder>(forSubstitution subst: Character, secondLevel: Bool, _ nb: B) -> B.Node? {
        for entry in all where entry.concurrency == secondLevel && entry.mangling == subst {
            return swiftType(kind: entry.kind, name: entry.typeName, nb)
        }
        return nil
    }

    /// The `(mangling, secondLevel)` for a stdlib-rooted nominal type, or
    /// `nil` when it is not a standard substitution — drives the remangler's
    /// `mangleStandardSubstitution`.
    static func substitution(forKind kind: SwiftSymbol.Kind, typeName: String) -> (mangling: Character, secondLevel: Bool)? {
        for entry in all where entry.kind == kind && entry.typeName == typeName {
            return (entry.mangling, entry.concurrency)
        }
        return nil
    }
}
