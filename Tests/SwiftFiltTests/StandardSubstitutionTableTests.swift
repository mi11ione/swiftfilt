// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt
import Testing

/// The standard-substitution table (`S<x>` first level, `Sc<x>` concurrency second level): every entry in apple/swift's `StandardTypesMangling.def` demangles to its stdlib type, remangles byte-exactly (which is what pins each entry's node KIND), and every letter outside the table is not a substitution at all.
@Suite("Standard substitution table")
struct StandardSubstitutionTableTests {
    /// `(mangling, typeName)` for the first level, transcribed from
    /// apple/swift's `include/swift/Demangling/StandardTypesMangling.def` —
    /// the same source the engine's table is generated from. Each row is
    /// checked against the reference-matching demangler below, so a
    /// transcription slip fails the suite rather than mirroring itself.
    static let firstLevel: [(mangling: String, typeName: String)] = [
        ("A", "AutoreleasingUnsafeMutablePointer"),
        ("a", "Array"),
        ("b", "Bool"),
        ("D", "Dictionary"),
        ("d", "Double"),
        ("f", "Float"),
        ("h", "Set"),
        ("I", "DefaultIndices"),
        ("i", "Int"),
        ("J", "Character"),
        ("N", "ClosedRange"),
        ("n", "Range"),
        ("O", "ObjectIdentifier"),
        ("P", "UnsafePointer"),
        ("p", "UnsafeMutablePointer"),
        ("R", "UnsafeBufferPointer"),
        ("r", "UnsafeMutableBufferPointer"),
        ("S", "String"),
        ("s", "Substring"),
        ("u", "UInt"),
        ("V", "UnsafeRawPointer"),
        ("v", "UnsafeMutableRawPointer"),
        ("W", "UnsafeRawBufferPointer"),
        ("w", "UnsafeMutableRawBufferPointer"),
        ("q", "Optional"),
        ("B", "BinaryFloatingPoint"),
        ("E", "Encodable"),
        ("e", "Decodable"),
        ("F", "FloatingPoint"),
        ("G", "RandomNumberGenerator"),
        ("H", "Hashable"),
        ("j", "Numeric"),
        ("K", "BidirectionalCollection"),
        ("k", "RandomAccessCollection"),
        ("L", "Comparable"),
        ("l", "Collection"),
        ("M", "MutableCollection"),
        ("m", "RangeReplaceableCollection"),
        ("Q", "Equatable"),
        ("T", "Sequence"),
        ("t", "IteratorProtocol"),
        ("U", "UnsignedInteger"),
        ("X", "RangeExpression"),
        ("x", "Strideable"),
        ("Y", "RawRepresentable"),
        ("y", "StringProtocol"),
        ("Z", "SignedInteger"),
        ("z", "BinaryInteger"),
    ]

    /// The concurrency (second-level) entries, reached as `Sc<x>`.
    static let secondLevel: [(mangling: String, typeName: String)] = [
        ("A", "Actor"),
        ("C", "CheckedContinuation"),
        ("c", "UnsafeContinuation"),
        ("E", "CancellationError"),
        ("e", "UnownedSerialExecutor"),
        ("F", "Executor"),
        ("f", "SerialExecutor"),
        ("G", "TaskGroup"),
        ("g", "ThrowingTaskGroup"),
        ("h", "TaskExecutor"),
        ("I", "AsyncIteratorProtocol"),
        ("i", "AsyncSequence"),
        ("J", "UnownedJob"),
        ("M", "MainActor"),
        ("P", "TaskPriority"),
        ("S", "AsyncStream"),
        ("s", "AsyncThrowingStream"),
        ("T", "Task"),
        ("t", "UnsafeCurrentTask"),
    ]

    /// A whole-symbol type mangling around one substitution: `$s<subst>D` is a
    /// `TypeMangling`, so it exercises the substitution through the ordinary
    /// public entry points.
    private static func symbol(_ subst: String, secondLevel: Bool) -> String {
        "$sS" + (secondLevel ? "c" : "") + subst + "D"
    }

    @Test func everyFirstLevelEntryDemanglesToItsStdlibType() {
        for row in Self.firstLevel {
            let mangled = Self.symbol(row.mangling, secondLevel: false)
            #expect(demangle(mangled, style: .qualified) == "Swift." + row.typeName, "\(mangled)")
        }
    }

    @Test func everySecondLevelEntryDemanglesToItsStdlibType() {
        for row in Self.secondLevel {
            let mangled = Self.symbol(row.mangling, secondLevel: true)
            #expect(demangle(mangled, style: .qualified) == "Swift." + row.typeName, "\(mangled)")
        }
    }

    /// Byte-exact remangling is what pins each entry's node KIND: the
    /// remangler finds a standard substitution by `(kind, typeName)`, so a row
    /// whose kind disagreed with the parser's would fail to match and mangle
    /// the long `Swift`-module form instead of the one-byte substitution.
    @Test func everyEntryRemanglesToItsOwnSubstitution() {
        for (rows, isSecond) in [(Self.firstLevel, false), (Self.secondLevel, true)] {
            for row in rows {
                let mangled = Self.symbol(row.mangling, secondLevel: isSecond)
                guard let tree = SwiftDemangler().demangle(symbol: mangled) else {
                    Issue.record("\(mangled) did not demangle")
                    continue
                }
                #expect(SwiftMangler().mangle(tree) == mangled)
            }
        }
    }

    /// Every ASCII LETTER outside the table is not a standard substitution.
    /// Digits are excluded deliberately: `S<digit>` is the repeated-substitution
    /// production, a different grammar rule that legitimately resolves.
    @Test func everyLetterOutsideTheTableIsNotASubstitution() {
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".map { String($0) }
        let firstManglings = Set(Self.firstLevel.map(\.mangling))
        let secondManglings = Set(Self.secondLevel.map(\.mangling))
        for letter in letters {
            if !firstManglings.contains(letter) {
                #expect(demangle(Self.symbol(letter, secondLevel: false)) == nil, "S\(letter)")
            }
            if !secondManglings.contains(letter) {
                #expect(demangle(Self.symbol(letter, secondLevel: true)) == nil, "Sc\(letter)")
            }
        }
    }

    /// The table is a bijection in both directions the engine uses it: no
    /// mangling byte repeats within a level, and no stdlib type name repeats
    /// across the whole table (the remangler's reverse lookup is keyed by
    /// `(kind, typeName)`, so a duplicated name would make one entry
    /// unreachable).
    @Test func theTableHasNoDuplicateManglingsOrTypeNames() {
        #expect(Set(Self.firstLevel.map(\.mangling)).count == Self.firstLevel.count)
        #expect(Set(Self.secondLevel.map(\.mangling)).count == Self.secondLevel.count)
        let allNames = Self.firstLevel.map(\.typeName) + Self.secondLevel.map(\.typeName)
        #expect(Set(allNames).count == allNames.count)
    }
}
