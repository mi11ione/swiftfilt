// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt
import Testing

/// Validates the metadata-path overload `demangle(symbolBytes:baseAddress:resolveSymbolicReference:)`:
/// control bytes `\x01…\x0C` decode a 4-byte little-endian offset and invoke the resolver
/// (kind/directness/value/reference-address); `\xFF` padding skipped; reserved bytes and a
/// refusing/absent resolver give `nil`; a resolved context registers as a substitution. This
/// is the reflection-metadata surface — symbolic references never appear in symbol-table names.
@Suite("Swift demangler symbolic references")
struct SwiftDemanglerSymbolicReferenceTests {
    private let demangler = SwiftDemangler()

    /// `$s` + one control byte + a 4-byte little-endian offset.
    private func bytes(control: UInt8, offset: [UInt8]) -> [UInt8] {
        [0x24, 0x73, control] + offset
    }

    /// A resolver that records its arguments into the identifier it returns, so
    /// the parsed tree carries them back for inspection (no shared state).
    private func recordingResolver() -> SymbolicReferenceResolver {
        { kind, directness, value, referenceAddress in
            SwiftSymbol(kind: .Identifier, name: "\(kind)|\(directness)|\(value)|\(referenceAddress)")
        }
    }

    private func resolvedIdentifier(_ tree: SwiftSymbol?) -> String? {
        tree?.children.first?.text
    }

    @Test func directContextReferencePassesDecodedFields() {
        let tree = demangler.demangle(
            symbolBytes: bytes(control: 0x01, offset: [4, 0, 0, 0]),
            baseAddress: 0x1000, resolveSymbolicReference: recordingResolver(),
        )
        // referenceAddress = baseAddress + byte offset of the 4-byte payload (3).
        #expect(resolvedIdentifier(tree) == "context|direct|4|4099")
    }

    @Test func everyControlByteMapsToItsKindAndDirectness() {
        let expected: [(UInt8, String)] = [
            (0x01, "context|direct"),
            (0x02, "context|indirect"),
            (0x09, "accessorFunctionReference|direct"),
            (0x0A, "uniqueExtendedExistentialTypeShape|direct"),
            (0x0B, "nonUniqueExtendedExistentialTypeShape|direct"),
            (0x0C, "objectiveCProtocol|direct"),
        ]
        for (control, prefix) in expected {
            let tree = demangler.demangle(
                symbolBytes: bytes(control: control, offset: [0, 0, 0, 0]),
                resolveSymbolicReference: recordingResolver(),
            )
            #expect(resolvedIdentifier(tree)?.hasPrefix(prefix) == true, "control \(control): \(String(describing: resolvedIdentifier(tree)))")
        }
    }

    @Test func negativeOffsetDecodesAsSignedLittleEndian() {
        let tree = demangler.demangle(
            symbolBytes: bytes(control: 0x01, offset: [0xFF, 0xFF, 0xFF, 0xFF]),
            baseAddress: 0, resolveSymbolicReference: recordingResolver(),
        )
        #expect(resolvedIdentifier(tree) == "context|direct|-1|3")
    }

    @Test func alignmentPaddingIsSkipped() {
        // 0xFF bytes before the control byte are padding and must be skipped.
        let raw: [UInt8] = [0x24, 0x73, 0xFF, 0xFF, 0x01, 7, 0, 0, 0]
        let tree = demangler.demangle(symbolBytes: raw, baseAddress: 0, resolveSymbolicReference: recordingResolver())
        // Control byte is now at index 4; payload starts at 5.
        #expect(resolvedIdentifier(tree) == "context|direct|7|5")
    }

    @Test func reservedControlBytesReturnNil() {
        for control: UInt8 in [0x03, 0x04, 0x05, 0x06, 0x07, 0x08] {
            let tree = demangler.demangle(
                symbolBytes: bytes(control: control, offset: [0, 0, 0, 0]),
                resolveSymbolicReference: recordingResolver(),
            )
            #expect(tree == nil, "reserved control \(control) should not demangle")
        }
    }

    @Test func refusingResolverReturnsNil() {
        let tree = demangler.demangle(
            symbolBytes: bytes(control: 0x01, offset: [0, 0, 0, 0]),
            resolveSymbolicReference: { _, _, _, _ in nil },
        )
        #expect(tree == nil)
    }

    @Test func absentResolverReturnsNil() {
        #expect(demangler.demangle(symbolBytes: bytes(control: 0x01, offset: [0, 0, 0, 0])) == nil)
    }

    @Test func truncatedOffsetReturnsNil() {
        // Fewer than 4 bytes follow the control byte.
        let tree = demangler.demangle(
            symbolBytes: [0x24, 0x73, 0x01, 0x00, 0x00],
            resolveSymbolicReference: recordingResolver(),
        )
        #expect(tree == nil)
    }

    @Test func resolvedShapeBuildsSymbolicExtendedExistentialType() {
        // `$s Si <0x0A shape ref> Xj`: the resolver supplies a unique
        // extended-existential-shape reference; the `Xj` operator pops it plus
        // the argument type into a SymbolicExtendedExistentialType, which then
        // re-mangles and prints.
        let resolver: SymbolicReferenceResolver = { kind, _, _, _ in
            kind == .uniqueExtendedExistentialTypeShape
                ? SwiftSymbol(kind: .UniqueExtendedExistentialTypeShapeSymbolicReference, index: 0)
                : SwiftSymbol(kind: .Identifier, name: "x")
        }
        let raw: [UInt8] = [0x24, 0x73, 0x53, 0x69, 0x0A, 0, 0, 0, 0, 0x58, 0x6A]
        let ast = demangler.demangle(symbolBytes: raw, baseAddress: 0, resolveSymbolicReference: resolver)
        #expect(ast != nil)
        #expect(ast?.treeDump().contains("SymbolicExtendedExistentialType") == true)
        if let ast {
            _ = SwiftMangler().mangle(ast)
            _ = SwiftDemanglerPrinter().print(ast, style: .full)
        }
    }

    @Test func symbolicExtendedExistentialShapeResolves() {
        /// `$s` <shape symbolic ref> <type> `Xj` — a symbolic extended-existential
        /// type. The resolver supplies the shape node the `Xj` operator pops.
        func shapeResolver(_ kind: SwiftSymbol.Kind) -> SymbolicReferenceResolver {
            { _, _, _, _ in SwiftSymbol(kind: kind, index: 0x1234) }
        }
        // 0x0A = unique shape, 0x0B = non-unique shape.
        for (control, shapeKind) in [
            (UInt8(0x0A), SwiftSymbol.Kind.UniqueExtendedExistentialTypeShapeSymbolicReference),
            (UInt8(0x0B), SwiftSymbol.Kind.NonUniqueExtendedExistentialTypeShapeSymbolicReference),
        ] {
            let raw: [UInt8] = [0x24, 0x73, control, 0, 0, 0, 0, 0x53, 0x69, 0x58, 0x6A] // $s <ref> Si Xj
            let ast = demangler.demangle(symbolBytes: raw, resolveSymbolicReference: shapeResolver(shapeKind))
            #expect(ast?.treeDump().contains("kind=SymbolicExtendedExistentialType") == true, "control \(control)")
            // Re-mangle the parsed tree to exercise the remangler's existential path.
            if let ast { _ = SwiftMangler().mangle(ast) }
        }
    }

    @Test func boundGenericOfSymbolicReferenceNominal() {
        // `$s` <type-symbolic-ref nominal> `y` <arg> `G` — a bound generic whose
        // nominal is a symbolic reference, so the args flatten into a
        // BoundGenericOtherNominalType.
        // A real resolver returns the referenced type wrapped in a `Type` node.
        let resolver: SymbolicReferenceResolver = { _, _, _, _ in
            SwiftSymbol(kind: .`Type`, child: SwiftSymbol(kind: .TypeSymbolicReference, index: 0))
        }
        let raw: [UInt8] = [0x24, 0x73, 0x01, 0, 0, 0, 0, 0x79, 0x53, 0x69, 0x47] // $s <ref> y Si G
        let ast = demangler.demangle(symbolBytes: raw, resolveSymbolicReference: resolver)
        let dump = ast?.treeDump() ?? "nil"
        #expect(dump.contains("kind=BoundGenericOtherNominalType"), "tree: \(dump.replacingOccurrences(of: "\n", with: " | "))")
    }

    @Test func resolvedContextRegistersAsSubstitution() {
        // A resolved context node is added to the substitution table, so a
        // following `AA…` back-reference can name it. The reference resolves to
        // a stdlib type; the back-reference (substitution 0) repeats it.
        let resolver: SymbolicReferenceResolver = { _, _, _, _ in
            SwiftSymbol(kind: .`Type`, child: SwiftSymbol(kind: .Structure, children: [
                SwiftSymbol(kind: .Module, name: "M"),
                SwiftSymbol(kind: .Identifier, name: "T"),
            ]))
        }
        // $s <ctx ref> AA  — the second component back-references substitution 0.
        let raw: [UInt8] = [0x24, 0x73, 0x01, 0, 0, 0, 0, 0x41, 0x41]
        let tree = demangler.demangle(symbolBytes: raw, baseAddress: 0, resolveSymbolicReference: resolver)
        // The back-reference resolves (non-nil tree) because the context was
        // registered as substitution 0.
        #expect(tree != nil)
    }

    @Test func typeBytesEntryParsesBareTypeGrammar() {
        // The reflection-metadata seam: bare type manglings carried as raw
        // bytes (no global prefix), with and without a symbolic reference.
        let printer = SwiftDemanglerPrinter()
        let plain = demangler.demangle(typeBytes: Array("Si".utf8))
        #expect(plain.map { printer.print($0, style: .full) } == "Swift.Int")
        // A control byte inside the type position routes through the resolver.
        let symbolic = demangler.demangle(
            typeBytes: [0x01, 4, 0, 0, 0],
            baseAddress: 0x1000,
            resolveSymbolicReference: { kind, directness, value, address in
                guard kind == .context, directness == .direct else { return nil }
                return SwiftSymbol(kind: .Structure, children: [
                    SwiftSymbol(kind: .Module, name: "M"),
                    SwiftSymbol(kind: .Identifier, name: "Ref\(value)at\(address)"),
                ])
            },
        )
        #expect(symbolic.map { printer.print($0, style: .full) } == "M.Ref4at4097")
        // Global-prefixed input is not a bare type: the entry declines.
        #expect(demangler.demangle(typeBytes: Array("$sSi".utf8)) == nil)
    }
}
