// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// Parser for the legacy `_T` Swift mangling (Swift ≤3) — a faithful port of
// `lib/Demangling/OldDemangler.cpp`. Real binaries still emit this scheme for
// Objective-C-exposed class and protocol type names (`_TtC…`, `_TtP…` — the
// names the ObjC runtime carries for Swift types), so it is reached via
// ``Demangler/demangleOldSymbolAsNode()`` for any `_T`-prefixed symbol that is
// not the Swift-4.0 `_T0` new-mangling prefix.
//
// It is a recursive-descent parser (distinct from the current scheme's postfix
// stack machine) producing the SAME ``SwiftSymbol`` node tree, so the printer
// and remangler need no special cases. Re-mangling an old symbol yields the
// current `$s` mangling (not byte-identical to the legacy input), so a
// byte-exact round-trip check does not apply to old-mangled inputs.

/// The legacy-mangling recursive-descent parser.
final class OldDemangler {
    private let text: [UInt8]
    // `@exclusivity(unchecked)`: skips the dynamic `swift_beginAccess` pair on
    // class-property mutation — sound as in ``Demangler`` (single-threaded,
    // non-reentrant, no overlapping formal access to a property).
    @exclusivity(unchecked) private var pos: Int
    @exclusivity(unchecked) private var substitutions: [SwiftSymbol] = []
    private static let maxDepth = 1024

    /// The parse window's end (exclusive): `text.count` for a whole-buffer
    /// parse; a candidate's upper bound when the windowed scanner hands a
    /// `_T` name over mid-buffer. Same cursor semantics either way — every
    /// bound below reads `end` where it read `text.count`. Required (no
    /// defaulted arm): the single caller — the ``Demangler`` bridge — always
    /// knows its window.
    private let end: Int

    init(text: [UInt8], position: Int, end: Int) {
        self.text = text
        pos = position
        self.end = end
    }

    // MARK: NameSource cursor

    private var isEmpty: Bool {
        pos >= end
    }

    private func peekByte() -> UInt8 {
        pos < end ? text[pos] : 0
    }

    private func nextByte() -> UInt8 {
        let c = peekByte()
        if pos < end { pos += 1 }
        return c
    }

    private func advance(_ n: Int) {
        pos = min(pos + n, end)
    }

    /// Consume `s` (one or more ASCII chars) if it is next.
    @discardableResult
    private func nextIf(_ s: String) -> Bool {
        let bytes = Array(s.utf8)
        guard pos + bytes.count <= end else { return false }
        for (i, b) in bytes.enumerated() where text[pos + i] != b {
            return false
        }
        pos += bytes.count
        return true
    }

    private func hasAtLeast(_ len: Int) -> Bool {
        pos + len <= end
    }

    /// Consume and return the rest of the input as a UTF-8 string.
    private func remainder() -> String {
        let slice = pos < end ? Array(text[pos ..< end]) : []
        pos = end
        return String(decoding: slice, as: UTF8.self)
    }

    // MARK: Static classification

    private static func isStartOfIdentifier(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || c == UInt8(ascii: "o")
    }

    private static func isStartOfNominalType(_ c: UInt8) -> Bool {
        c == UInt8(ascii: "C") || c == UInt8(ascii: "V") || c == UInt8(ascii: "O")
    }

    private static func isStartOfEntity(_ c: UInt8) -> Bool {
        switch c {
        case UInt8(ascii: "F"), UInt8(ascii: "I"), UInt8(ascii: "v"),
             UInt8(ascii: "P"), UInt8(ascii: "s"), UInt8(ascii: "Z"):
            true
        default:
            isStartOfNominalType(c)
        }
    }

    private static func nominalTypeMarkerToNodeKind(_ c: UInt8) -> SwiftSymbol.Kind {
        switch c {
        case UInt8(ascii: "C"): .Class
        case UInt8(ascii: "V"): .Structure
        case UInt8(ascii: "O"): .Enum
        default: .Identifier
        }
    }

    // MARK: Entry

    /// Demangle a complete old-mangling symbol (the full text including its
    /// `_T` prefix), or `nil`.
    func demangleTopLevelOld() -> SwiftSymbol? {
        guard nextIf("_T") else { return nil }
        var topLevel = SwiftSymbol(kind: .Global)

        if nextIf("TS") {
            repeat {
                guard let attr = demangleSpecializedAttribute(0) else { return nil }
                topLevel.addChild(attr)
                substitutions.removeAll(keepingCapacity: true)
            } while nextIf("_TTS")
            guard nextIf("_T") else {
                return nil
            }
        } else if nextIf("To") {
            topLevel.addChild(SwiftSymbol(kind: .ObjCAttribute))
        } else if nextIf("TO") {
            topLevel.addChild(SwiftSymbol(kind: .NonObjCAttribute))
        } else if nextIf("TD") {
            topLevel.addChild(SwiftSymbol(kind: .DynamicAttribute))
        } else if nextIf("Td") {
            topLevel.addChild(SwiftSymbol(kind: .DirectMethodReferenceAttribute))
        } else if nextIf("TV") {
            topLevel.addChild(SwiftSymbol(kind: .VTableAttribute))
        }

        guard let global = demangleGlobal(0) else { return nil }
        topLevel.addChild(global)

        if !isEmpty {
            topLevel.addChild(SwiftSymbol(kind: .Suffix, name: remainder()))
        }
        return topLevel
    }

    // MARK: Numbers / indices

    private func demangleNatural() -> UInt64? {
        if isEmpty { return nil }
        var c = peekByte()
        if c < 0x30 || c > 0x39 { return nil }
        pos += 1
        var num = UInt64(c - 0x30)
        while !isEmpty {
            c = peekByte()
            if c < 0x30 || c > 0x39 { break }
            num = 10 &* num &+ UInt64(c - 0x30)
            pos += 1
        }
        return num
    }

    private func demangleBuiltinSize() -> UInt64? {
        guard let num = demangleNatural(), nextIf("_") else { return nil }
        return num
    }

    private func demangleIndex() -> UInt64? {
        if nextIf("_") { return 0 }
        if let num = demangleNatural(), nextIf("_") { return num + 1 }
        return nil
    }

    private func demangleIndexAsNode(_ kind: SwiftSymbol.Kind = .Number) -> SwiftSymbol? {
        guard let index = demangleIndex() else { return nil }
        return SwiftSymbol(kind: kind, index: index)
    }

    private func demangleValueWitnessKind() -> Int? {
        guard hasAtLeast(2) else { return nil }
        let code = String(decoding: text[pos ..< pos + 2], as: UTF8.self)
        pos += 2
        return ValueWitnessKinds.index(forCode: code)
    }

    // MARK: Builders

    private func createSwiftType(_ kind: SwiftSymbol.Kind, _ name: String) -> SwiftSymbol {
        SwiftSymbol(kind: kind, children: [
            SwiftSymbol(kind: .Module, name: SwiftManglingConstants.stdlibName),
            SwiftSymbol(kind: .Identifier, name: name),
        ])
    }

    private func childOf(_ kind: SwiftSymbol.Kind, _ child: SwiftSymbol?) -> SwiftSymbol? {
        guard let child else { return nil }
        return SwiftSymbol(kind: kind, child: child)
    }

    // MARK: Global dispatch

    private func demangleGlobal(_ depth: Int) -> SwiftSymbol? {
        if depth > Self.maxDepth || isEmpty { return nil }

        if nextIf("M") {
            if nextIf("P") { return wrapType(.GenericTypeMetadataPattern, depth) }
            if nextIf("a") { return wrapType(.TypeMetadataAccessFunction, depth) }
            if nextIf("L") { return wrapType(.TypeMetadataLazyCache, depth) }
            if nextIf("m") { return wrapType(.Metaclass, depth) }
            if nextIf("n") { return wrapType(.NominalTypeDescriptor, depth) }
            if nextIf("f") { return wrapType(.FullTypeMetadata, depth) }
            if nextIf("p") {
                var node = SwiftSymbol(kind: .ProtocolDescriptor)
                guard let proto = demangleProtocolName(depth + 1) else { return nil }
                node.addChild(proto); return node
            }
            return wrapType(.TypeMetadata, depth)
        }

        if nextIf("PA") {
            let kind: SwiftSymbol.Kind = nextIf("o") ? .PartialApplyObjCForwarder : .PartialApplyForwarder
            var forwarder = SwiftSymbol(kind: kind)
            if nextIf("__T") {
                guard let global = demangleGlobal(depth + 1) else { return nil }
                forwarder.addChild(global)
            }
            return forwarder
        }

        if nextIf("t") { return wrapType(.TypeMangling, depth) }

        if nextIf("w") {
            guard let witnessKind = demangleValueWitnessKind() else { return nil }
            var witness = SwiftSymbol(kind: .ValueWitness)
            witness.addChild(SwiftSymbol(kind: .Index, index: UInt64(witnessKind)))
            guard let type = demangleType(depth + 1) else { return nil }
            witness.addChild(type)
            return witness
        }

        if nextIf("W") { return demangleWitnessOld(depth) }

        if nextIf("T") {
            if nextIf("R") {
                var thunk = SwiftSymbol(kind: .ReabstractionThunkHelper)
                guard demangleReabstractSignature(&thunk, depth + 1) else { return nil }
                return thunk
            }
            if nextIf("r") {
                var thunk = SwiftSymbol(kind: .ReabstractionThunk)
                guard demangleReabstractSignature(&thunk, depth + 1) else { return nil }
                return thunk
            }
            if nextIf("W") {
                var thunk = SwiftSymbol(kind: .ProtocolWitness)
                guard let conf = demangleProtocolConformance(depth + 1) else { return nil }
                thunk.addChild(conf)
                guard let entity = demangleEntity(depth + 1) else { return nil }
                thunk.addChild(entity)
                return thunk
            }
            return nil
        }

        return demangleEntity(depth + 1)
    }

    /// `<metadata-op> Type` → a node of `kind` whose child is the demangled type.
    private func wrapType(_ kind: SwiftSymbol.Kind, _ depth: Int) -> SwiftSymbol? {
        guard let type = demangleType(depth + 1) else { return nil }
        return SwiftSymbol(kind: kind, child: type)
    }

    private func demangleWitnessOld(_ depth: Int) -> SwiftSymbol? {
        if nextIf("V") { return wrapType(.ValueWitnessTable, depth) }
        if nextIf("v") {
            guard let directness = demangleDirectnessNode(),
                  let entity = demangleEntity(depth + 1) else { return nil }
            return SwiftSymbol(kind: .FieldOffset, children: [directness, entity])
        }
        if nextIf("P") { return childOf(.ProtocolWitnessTable, demangleProtocolConformance(depth + 1)) }
        if nextIf("G") { return childOf(.GenericProtocolWitnessTable, demangleProtocolConformance(depth + 1)) }
        if nextIf("I") {
            return childOf(.GenericProtocolWitnessTableInstantiationFunction, demangleProtocolConformance(depth + 1))
        }
        if nextIf("l") {
            guard let type = demangleType(depth + 1), let conf = demangleProtocolConformance(depth + 1) else { return nil }
            return SwiftSymbol(kind: .LazyProtocolWitnessTableAccessor, children: [type, conf])
        }
        if nextIf("L") {
            guard let type = demangleType(depth + 1), let conf = demangleProtocolConformance(depth + 1) else { return nil }
            return SwiftSymbol(kind: .LazyProtocolWitnessTableCacheVariable, children: [type, conf])
        }
        if nextIf("a") { return childOf(.ProtocolWitnessTableAccessor, demangleProtocolConformance(depth + 1)) }
        if nextIf("t") {
            guard let conf = demangleProtocolConformance(depth + 1), let name = demangleDeclName(depth + 1) else { return nil }
            return SwiftSymbol(kind: .AssociatedTypeMetadataAccessor, children: [conf, name])
        }
        if nextIf("T") {
            guard let conf = demangleProtocolConformance(depth + 1),
                  let name = demangleDeclName(depth + 1),
                  let proto = demangleProtocolName(depth + 1) else { return nil }
            return SwiftSymbol(kind: .AssociatedTypeWitnessTableAccessor, children: [conf, name, proto])
        }
        return nil
    }

    private func demangleDirectnessNode() -> SwiftSymbol? {
        if nextIf("d") { return SwiftSymbol(kind: .Directness, index: 0) }
        if nextIf("i") { return SwiftSymbol(kind: .Directness, index: 1) }
        return nil
    }

    // MARK: Specializations

    private func demangleSpecializedAttribute(_ depth: Int) -> SwiftSymbol? {
        var isNotReAbstracted = false
        if nextIf("g") || { isNotReAbstracted = nextIf("r"); return isNotReAbstracted }() {
            var spec = SwiftSymbol(kind: isNotReAbstracted ? .GenericSpecializationNotReAbstracted : .GenericSpecialization)
            if nextIf("q") { spec.addChild(SwiftSymbol(kind: .IsSerialized)) }
            let passID = Int(nextByte()) - 48
            guard passID >= 0 else { return nil }
            spec.addChild(SwiftSymbol(kind: .SpecializationPassID, index: UInt64(passID)))
            return demangleGenericSpecialization(&spec, depth + 1)
        }
        if nextIf("f") {
            var spec = SwiftSymbol(kind: .FunctionSignatureSpecialization)
            if nextIf("q") { spec.addChild(SwiftSymbol(kind: .IsSerialized)) }
            let passID = Int(nextByte()) - 48
            guard passID >= 0 else { return nil }
            spec.addChild(SwiftSymbol(kind: .SpecializationPassID, index: UInt64(passID)))
            return demangleFunctionSignatureSpecialization(&spec, depth + 1)
        }
        return nil
    }

    private func demangleGenericSpecialization(_ spec: inout SwiftSymbol, _ depth: Int) -> SwiftSymbol? {
        if depth > Self.maxDepth { return nil }
        while !nextIf("_") {
            var param = SwiftSymbol(kind: .GenericSpecializationParam)
            guard let type = demangleType(depth + 1) else { return nil }
            param.addChild(type)
            while !nextIf("_") {
                guard let conf = demangleProtocolConformance(depth + 1) else { return nil }
                param.addChild(conf)
            }
            spec.addChild(param)
        }
        return spec
    }

    private func funcSpecKind(_ value: UInt64) -> SwiftSymbol {
        SwiftSymbol(kind: .FunctionSignatureSpecializationParamKind, index: value)
    }

    private func demangleFuncSigSpecializationConstantProp(_ parent: inout SwiftSymbol, _ depth: Int) -> Bool {
        if nextIf("fr") {
            guard let name = demangleIdentifier(depth + 1), nextIf("_") else { return false }
            parent.addChild(funcSpecKind(0)) // ConstantPropFunction
            parent.addChild(SwiftSymbol(kind: .Identifier, name: name.text ?? ""))
            return true
        }
        if nextIf("g") {
            guard let name = demangleIdentifier(depth + 1), nextIf("_") else { return false }
            parent.addChild(funcSpecKind(1)) // ConstantPropGlobal
            parent.addChild(SwiftSymbol(kind: .Identifier, name: name.text ?? ""))
            return true
        }
        if nextIf("i") {
            guard let str = readUntilUnderscore(), nextIf("_") else { return false }
            parent.addChild(funcSpecKind(2)) // ConstantPropInteger
            parent.addChild(SwiftSymbol(kind: .FunctionSignatureSpecializationParamPayload, name: str))
            return true
        }
        if nextIf("fl") {
            guard let str = readUntilUnderscore(), nextIf("_") else { return false }
            parent.addChild(funcSpecKind(3)) // ConstantPropFloat
            parent.addChild(SwiftSymbol(kind: .FunctionSignatureSpecializationParamPayload, name: str))
            return true
        }
        if nextIf("s") {
            guard nextIf("e") else { return false }
            let encoding = peekByte()
            guard encoding == UInt8(ascii: "0") || encoding == UInt8(ascii: "1") else { return false }
            let encodingStr = encoding == UInt8(ascii: "0") ? "u8" : "u16"
            advance(1)
            guard nextIf("v"), let str = demangleIdentifier(depth + 1), nextIf("_") else { return false }
            parent.addChild(funcSpecKind(4)) // ConstantPropString
            parent.addChild(SwiftSymbol(kind: .FunctionSignatureSpecializationParamPayload, name: encodingStr))
            parent.addChild(SwiftSymbol(kind: .Identifier, name: str.text ?? ""))
            return true
        }
        return false
    }

    private func readUntilUnderscore() -> String? {
        var bytes: [UInt8] = []
        while !isEmpty, peekByte() != UInt8(ascii: "_") {
            bytes.append(nextByte())
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func demangleFuncSigSpecializationClosureProp(_ parent: inout SwiftSymbol, _ depth: Int) -> Bool {
        guard let name = demangleIdentifier(depth + 1) else { return false }
        parent.addChild(funcSpecKind(5)) // ClosureProp
        parent.addChild(SwiftSymbol(kind: .FunctionSignatureSpecializationParamPayload, name: name.text ?? ""))
        while peekByte() != UInt8(ascii: "_"), let type = demangleType(depth + 1) {
            parent.addChild(type)
        }
        return nextIf("_")
    }

    private func demangleFunctionSignatureSpecialization(_ spec: inout SwiftSymbol, _ depth: Int) -> SwiftSymbol? {
        while !nextIf("_") {
            var param = SwiftSymbol(kind: .FunctionSignatureSpecializationParam)
            if nextIf("n_") {
                // empty
            } else if nextIf("cp") {
                guard demangleFuncSigSpecializationConstantProp(&param, depth + 1) else { return nil }
            } else if nextIf("cl") {
                guard demangleFuncSigSpecializationClosureProp(&param, depth + 1) else { return nil }
            } else if nextIf("i_") {
                param.addChild(funcSpecKind(6)) // BoxToValue
            } else if nextIf("k_") {
                param.addChild(funcSpecKind(7)) // BoxToStack
            } else if nextIf("r_") {
                param.addChild(funcSpecKind(8)) // InOutToOut
            } else {
                var value: UInt64 = 0
                if nextIf("d") { value |= 1 << 6 } // Dead
                if nextIf("g") { value |= 1 << 7 } // OwnedToGuaranteed
                if nextIf("o") { value |= 1 << 9 } // GuaranteedToOwned
                if nextIf("s") { value |= 1 << 8 } // SROA
                guard nextIf("_"), value != 0 else { return nil }
                param.addChild(funcSpecKind(value))
            }
            spec.addChild(param)
        }
        return spec
    }

    // MARK: Names / identifiers

    private func demangleDeclName(_ depth: Int) -> SwiftSymbol? {
        if nextIf("L") {
            guard let discriminator = demangleIndexAsNode(), let name = demangleIdentifier(depth + 1) else { return nil }
            return SwiftSymbol(kind: .LocalDeclName, children: [discriminator, name])
        }
        if nextIf("P") {
            guard let discriminator = demangleIdentifier(depth + 1), let name = demangleIdentifier(depth + 1) else { return nil }
            return SwiftSymbol(kind: .PrivateDeclName, children: [discriminator, name])
        }
        return demangleIdentifier(depth + 1)
    }

    private func demangleIdentifier(_: Int, kind: SwiftSymbol.Kind? = nil) -> SwiftSymbol? {
        if isEmpty { return nil }
        let isPunycoded = nextIf("X")
        var kind = kind
        var isOperator = false
        if nextIf("o") {
            isOperator = true
            if kind != nil { return nil }
            switch nextByte() {
            case UInt8(ascii: "p"): kind = .PrefixOperator
            case UInt8(ascii: "P"): kind = .PostfixOperator
            case UInt8(ascii: "i"): kind = .InfixOperator
            default: return nil
            }
        }
        let resolvedKind = kind ?? .Identifier

        guard let length = demangleNatural(), hasAtLeast(Int(length)) else { return nil }
        let slice = Array(text[pos ..< pos + Int(length)])
        advance(Int(length))

        var identifier: String
        if isPunycoded {
            guard let decoded = SwiftPunycode.decodeToString(slice) else { return nil }
            identifier = decoded
        } else {
            identifier = String(decoding: slice, as: UTF8.self)
        }
        if identifier.isEmpty { return nil }

        if isOperator {
            // Reverse operator-char table: index = letter - 'a'; ' ' = invalid.
            let opCharTable = Array("& @/= >    <*!|+?%-~   ^ .".utf8)
            var decoded: [UInt8] = []
            for byte in Array(identifier.utf8) {
                if byte >= 0x80 { decoded.append(byte); continue }
                guard byte >= UInt8(ascii: "a"), byte <= UInt8(ascii: "z") else { return nil }
                let o = opCharTable[Int(byte - UInt8(ascii: "a"))]
                if o == UInt8(ascii: " ") { return nil }
                decoded.append(o)
            }
            identifier = String(decoding: decoded, as: UTF8.self)
        }
        return SwiftSymbol(kind: resolvedKind, name: identifier)
    }

    // MARK: Substitutions, modules, declarations

    private func demangleSubstitutionIndex(_: Int) -> SwiftSymbol? {
        if isEmpty { return nil }
        if nextIf("o") { return SwiftSymbol(kind: .Module, name: SwiftManglingConstants.objCModule) }
        if nextIf("C") { return SwiftSymbol(kind: .Module, name: SwiftManglingConstants.clangImporterModule) }
        if nextIf("a") { return createSwiftType(.Structure, "Array") }
        if nextIf("b") { return createSwiftType(.Structure, "Bool") }
        if nextIf("c") { return createSwiftType(.Structure, "UnicodeScalar") }
        if nextIf("d") { return createSwiftType(.Structure, "Double") }
        if nextIf("f") { return createSwiftType(.Structure, "Float") }
        if nextIf("i") { return createSwiftType(.Structure, "Int") }
        if nextIf("V") { return createSwiftType(.Structure, "UnsafeRawPointer") }
        if nextIf("v") { return createSwiftType(.Structure, "UnsafeMutableRawPointer") }
        if nextIf("P") { return createSwiftType(.Structure, "UnsafePointer") }
        if nextIf("p") { return createSwiftType(.Structure, "UnsafeMutablePointer") }
        if nextIf("q") { return createSwiftType(.Enum, "Optional") }
        if nextIf("Q") { return createSwiftType(.Enum, "ImplicitlyUnwrappedOptional") }
        if nextIf("R") { return createSwiftType(.Structure, "UnsafeBufferPointer") }
        if nextIf("r") { return createSwiftType(.Structure, "UnsafeMutableBufferPointer") }
        if nextIf("S") { return createSwiftType(.Structure, "String") }
        if nextIf("u") { return createSwiftType(.Structure, "UInt") }
        guard let index = demangleIndex(), Int(index) < substitutions.count else { return nil }
        return substitutions[Int(index)]
    }

    private func demangleModule(_ depth: Int) -> SwiftSymbol? {
        if nextIf("s") { return SwiftSymbol(kind: .Module, name: SwiftManglingConstants.stdlibName) }
        if nextIf("S") {
            guard let module = demangleSubstitutionIndex(depth + 1), module.kind == .Module else { return nil }
            return module
        }
        guard let module = demangleIdentifier(depth + 1, kind: .Module) else { return nil }
        substitutions.append(module)
        return module
    }

    private func demangleDeclarationName(_ kind: SwiftSymbol.Kind, _ depth: Int) -> SwiftSymbol? {
        guard let context = demangleContext(depth + 1), let name = demangleDeclName(depth + 1) else { return nil }
        let decl = SwiftSymbol(kind: kind, children: [context, name])
        substitutions.append(decl)
        return decl
    }

    private func demangleProtocolName(_ depth: Int) -> SwiftSymbol? {
        guard let proto = demangleProtocolNameImpl(depth) else { return nil }
        return SwiftSymbol(kind: .`Type`, child: proto)
    }

    private func demangleProtocolNameGivenContext(_ context: SwiftSymbol, _ depth: Int) -> SwiftSymbol? {
        guard let name = demangleDeclName(depth + 1) else { return nil }
        let proto = SwiftSymbol(kind: .protocolNode, children: [context, name])
        substitutions.append(proto)
        return proto
    }

    private func demangleProtocolNameImpl(_ depth: Int) -> SwiftSymbol? {
        if depth > Self.maxDepth { return nil }
        if nextIf("S") {
            guard let sub = demangleSubstitutionIndex(depth + 1) else { return nil }
            if sub.kind == .protocolNode { return sub }
            guard sub.kind == .Module else { return nil }
            return demangleProtocolNameGivenContext(sub, depth + 1)
        }
        if nextIf("s") {
            return demangleProtocolNameGivenContext(SwiftSymbol(kind: .Module, name: SwiftManglingConstants.stdlibName), depth + 1)
        }
        return demangleDeclarationName(.protocolNode, depth + 1)
    }

    private func demangleNominalType(_ depth: Int) -> SwiftSymbol? {
        if nextIf("S") { return demangleSubstitutionIndex(depth + 1) }
        if nextIf("V") { return demangleDeclarationName(.Structure, depth + 1) }
        if nextIf("O") { return demangleDeclarationName(.Enum, depth + 1) }
        if nextIf("C") { return demangleDeclarationName(.Class, depth + 1) }
        if nextIf("P") { return demangleDeclarationName(.protocolNode, depth + 1) }
        return nil
    }

    // MARK: Bound generics

    private func demangleBoundGenericArgs(_ nominalType0: SwiftSymbol, _ depth: Int) -> SwiftSymbol? {
        var nominalType = nominalType0
        if nominalType.children.isEmpty { return nil }
        let parentOrModule = nominalType.children[0]
        if parentOrModule.kind != .Module, parentOrModule.kind != .Function, parentOrModule.kind != .Extension {
            guard let boundParent = demangleBoundGenericArgs(parentOrModule, depth + 1) else { return nil }
            var rebuilt = SwiftSymbol(kind: nominalType.kind, child: boundParent)
            for idx in 1 ..< nominalType.children.count {
                rebuilt.addChild(nominalType.children[idx])
            }
            nominalType = rebuilt
        }
        var args = SwiftSymbol(kind: .TypeList)
        while !nextIf("_") {
            guard let type = demangleType(depth + 1) else { return nil }
            args.addChild(type)
            if isEmpty { return nil }
        }
        if args.children.isEmpty { return nominalType }
        let unboundType = SwiftSymbol(kind: .`Type`, child: nominalType)
        let kind: SwiftSymbol.Kind
        switch nominalType.kind {
        case .Class: kind = .BoundGenericClass
        case .Structure: kind = .BoundGenericStructure
        case .Enum: kind = .BoundGenericEnum
        default: return nil
        }
        return SwiftSymbol(kind: kind, children: [unboundType, args])
    }

    private func demangleBoundGenericType(_ depth: Int) -> SwiftSymbol? {
        guard let nominalType = demangleNominalType(depth + 1) else { return nil }
        return demangleBoundGenericArgs(nominalType, depth + 1)
    }

    // MARK: Context

    private func demangleContext(_ depth: Int) -> SwiftSymbol? {
        if isEmpty { return nil }
        if nextIf("E") {
            guard let defModule = demangleModule(depth + 1), let type = demangleContext(depth + 1) else { return nil }
            return SwiftSymbol(kind: .Extension, children: [defModule, type])
        }
        if nextIf("e") {
            guard let defModule = demangleModule(depth + 1), let sig = demangleGenericSignature(depth + 1),
                  let type = demangleContext(depth + 1) else { return nil }
            return SwiftSymbol(kind: .Extension, children: [defModule, type, sig])
        }
        if nextIf("S") { return demangleSubstitutionIndex(depth + 1) }
        if nextIf("s") { return SwiftSymbol(kind: .Module, name: SwiftManglingConstants.stdlibName) }
        if nextIf("G") { return demangleBoundGenericType(depth + 1) }
        if Self.isStartOfEntity(peekByte()) { return demangleEntity(depth + 1) }
        return demangleModule(depth + 1)
    }

    private func demangleProtocolList(_ depth: Int) -> SwiftSymbol? {
        var typeList = SwiftSymbol(kind: .TypeList)
        while !nextIf("_") {
            guard let proto = demangleProtocolName(depth + 1) else { return nil }
            typeList.addChild(proto)
        }
        return SwiftSymbol(kind: .ProtocolList, child: typeList)
    }

    private func demangleProtocolConformance(_ depth: Int) -> SwiftSymbol? {
        guard let type = demangleType(depth + 1), let proto = demangleProtocolName(depth + 1),
              let context = demangleContext(depth + 1) else { return nil }
        return SwiftSymbol(kind: .ProtocolConformance, children: [type, proto, context])
    }

    // MARK: Entities

    private func demangleEntity(_ depth: Int) -> SwiftSymbol? {
        if depth > Self.maxDepth { return nil }
        let isStatic = nextIf("Z")

        let entityBasicKind: SwiftSymbol.Kind
        if nextIf("F") { entityBasicKind = .Function }
        else if nextIf("v") { entityBasicKind = .Variable }
        else if nextIf("I") { entityBasicKind = .Initializer }
        else if nextIf("i") { entityBasicKind = .Subscript }
        else { return demangleNominalType(depth + 1) }

        guard let context = demangleContext(depth + 1) else { return nil }

        var entityKind: SwiftSymbol.Kind
        var hasType = true
        var wrapEntity = false
        var name: SwiftSymbol?

        if nextIf("D") { entityKind = .Deallocator; hasType = false }
        else if nextIf("Z") { entityKind = .IsolatedDeallocator; hasType = false }
        else if nextIf("d") { entityKind = .Destructor; hasType = false }
        else if nextIf("e") { entityKind = .IVarInitializer; hasType = false }
        else if nextIf("E") { entityKind = .IVarDestroyer; hasType = false }
        else if nextIf("C") { entityKind = .Allocator }
        else if nextIf("c") { entityKind = .Constructor }
        else if nextIf("a") {
            wrapEntity = true
            if nextIf("O") { entityKind = .OwningMutableAddressor }
            else if nextIf("o") { entityKind = .NativeOwningMutableAddressor }
            else if nextIf("p") { entityKind = .NativePinningMutableAddressor }
            else if nextIf("u") { entityKind = .UnsafeMutableAddressor }
            else { return nil }
            guard let n = demangleDeclName(depth + 1) else { return nil }; name = n
        } else if nextIf("l") {
            wrapEntity = true
            if nextIf("O") { entityKind = .OwningAddressor }
            else if nextIf("o") { entityKind = .NativeOwningAddressor }
            else if nextIf("p") { entityKind = .NativePinningAddressor }
            else if nextIf("u") { entityKind = .UnsafeAddressor }
            else { return nil }
            guard let n = demangleDeclName(depth + 1) else { return nil }; name = n
        } else if nextIf("g") {
            wrapEntity = true; entityKind = .Getter
            guard let n = demangleDeclName(depth + 1) else { return nil }; name = n
        } else if nextIf("G") {
            wrapEntity = true; entityKind = .GlobalGetter
            guard let n = demangleDeclName(depth + 1) else { return nil }; name = n
        } else if nextIf("s") {
            wrapEntity = true; entityKind = .Setter
            guard let n = demangleDeclName(depth + 1) else { return nil }; name = n
        } else if nextIf("m") {
            wrapEntity = true; entityKind = .MaterializeForSet
            guard let n = demangleDeclName(depth + 1) else { return nil }; name = n
        } else if nextIf("w") {
            wrapEntity = true; entityKind = .WillSet
            guard let n = demangleDeclName(depth + 1) else { return nil }; name = n
        } else if nextIf("W") {
            wrapEntity = true; entityKind = .DidSet
            guard let n = demangleDeclName(depth + 1) else { return nil }; name = n
        } else if nextIf("r") {
            wrapEntity = true; entityKind = .ReadAccessor
            guard let n = demangleDeclName(depth + 1) else { return nil }; name = n
        } else if nextIf("M") {
            wrapEntity = true; entityKind = .ModifyAccessor
            guard let n = demangleDeclName(depth + 1) else { return nil }; name = n
        } else if nextIf("U") {
            entityKind = .ExplicitClosure
            guard let n = demangleIndexAsNode() else { return nil }; name = n
        } else if nextIf("u") {
            entityKind = .ImplicitClosure
            guard let n = demangleIndexAsNode() else { return nil }; name = n
        } else if entityBasicKind == .Initializer {
            if nextIf("A") {
                entityKind = .DefaultArgumentInitializer
                guard let n = demangleIndexAsNode() else { return nil }; name = n
            } else if nextIf("i") {
                entityKind = .Initializer
            } else { return nil }
            hasType = false
        } else {
            entityKind = entityBasicKind
            guard let n = demangleDeclName(depth + 1) else { return nil }; name = n
        }

        var entity = SwiftSymbol(kind: entityKind)
        if wrapEntity {
            var isSubscript = false
            if let n = name {
                switch n.kind {
                case .Identifier:
                    if n.text == "subscript" { isSubscript = true; name = nil }
                case .PrivateDeclName:
                    if n.children.count > 1, n.children[1].text == "subscript" {
                        isSubscript = true
                        name = SwiftSymbol(kind: .PrivateDeclName, child: n.children[0])
                    }
                default: break
                }
            }
            var wrapped = SwiftSymbol(kind: isSubscript ? .Subscript : .Variable)
            wrapped.addChild(context)
            if !isSubscript, let n = name { wrapped.addChild(n) }
            if hasType {
                guard let type = demangleType(depth + 1) else { return nil }
                wrapped.addChild(type)
            }
            if isSubscript, let n = name { wrapped.addChild(n) }
            entity.addChild(wrapped)
        } else {
            entity.addChild(context)
            if let n = name { entity.addChild(n) }
            if hasType {
                guard let type = demangleType(depth + 1) else { return nil }
                entity.addChild(type)
            }
        }

        if isStatic { return SwiftSymbol(kind: .Static, child: entity) }
        return entity
    }

    // MARK: Generic params / dependent types

    private func getDependentGenericParamType(_ paramDepth: UInt64, _ index: UInt64) -> SwiftSymbol {
        SwiftSymbol(kind: .DependentGenericParamType, children: [
            SwiftSymbol(kind: .Index, index: paramDepth),
            SwiftSymbol(kind: .Index, index: index),
        ])
    }

    private func demangleGenericParamIndex(_: Int) -> SwiftSymbol? {
        if nextIf("d") {
            guard let pd = demangleIndex(), let idx = demangleIndex() else { return nil }
            return getDependentGenericParamType(pd + 1, idx)
        }
        if nextIf("x") { return getDependentGenericParamType(0, 0) }
        guard let idx = demangleIndex() else { return nil }
        return getDependentGenericParamType(0, idx + 1)
    }

    private func demangleDependentMemberTypeName(_ base: SwiftSymbol, _ depth: Int) -> SwiftSymbol? {
        var assocTy: SwiftSymbol?
        if nextIf("S") {
            guard let sub = demangleSubstitutionIndex(depth + 1), sub.kind == .DependentAssociatedTypeRef else { return nil }
            assocTy = sub
        } else {
            var protocolNode: SwiftSymbol?
            if nextIf("P") {
                guard let p = demangleProtocolName(depth + 1) else { return nil }
                protocolNode = p
            }
            guard let id = demangleIdentifier(depth + 1) else { return nil }
            var at = SwiftSymbol(kind: .DependentAssociatedTypeRef, child: id)
            if let protocolNode { at.addChild(protocolNode) }
            substitutions.append(at)
            assocTy = at
        }
        guard let assocTy else { return nil }
        return SwiftSymbol(kind: .DependentMemberType, children: [base, assocTy])
    }

    private func demangleAssociatedTypeSimple(_ depth: Int) -> SwiftSymbol? {
        guard let base = demangleGenericParamIndex(depth + 1) else { return nil }
        let nodeType = SwiftSymbol(kind: .`Type`, child: base)
        return demangleDependentMemberTypeName(nodeType, depth + 1)
    }

    private func demangleAssociatedTypeCompound(_ depth: Int) -> SwiftSymbol? {
        guard let baseIndex = demangleGenericParamIndex(depth + 1) else { return nil }
        var base = baseIndex
        while !nextIf("_") {
            let nodeType = SwiftSymbol(kind: .`Type`, child: base)
            guard let next = demangleDependentMemberTypeName(nodeType, depth + 1) else { return nil }
            base = next
        }
        return base
    }

    private func demangleDependentType(_ depth: Int) -> SwiftSymbol? {
        if isEmpty { return nil }
        let c = peekByte()
        if c != UInt8(ascii: "d"), c != UInt8(ascii: "_"), !ManglingChars.isDigit(c) {
            guard let baseType = demangleType(depth + 1) else { return nil }
            return demangleDependentMemberTypeName(baseType, depth + 1)
        }
        return demangleGenericParamIndex(depth + 1)
    }

    private func demangleConstrainedTypeImpl(_ depth: Int) -> SwiftSymbol? {
        if nextIf("w") { return demangleAssociatedTypeSimple(depth + 1) }
        if nextIf("W") { return demangleAssociatedTypeCompound(depth + 1) }
        return demangleGenericParamIndex(depth + 1)
    }

    private func demangleConstrainedType(_ depth: Int) -> SwiftSymbol? {
        guard let type = demangleConstrainedTypeImpl(depth) else { return nil }
        return SwiftSymbol(kind: .`Type`, child: type)
    }

    // MARK: Generic signatures / requirements

    private func demangleGenericSignature(_ depth: Int, isPseudogeneric: Bool = false) -> SwiftSymbol? {
        var sig = SwiftSymbol(kind: isPseudogeneric ? .DependentPseudogenericSignature : .DependentGenericSignature)
        var count: UInt64 = .max
        while peekByte() != UInt8(ascii: "R"), peekByte() != UInt8(ascii: "r") {
            if nextIf("z") {
                count = 0
            } else if let idx = demangleIndex() {
                count = idx + 1
            } else {
                return nil
            }
            sig.addChild(SwiftSymbol(kind: .DependentGenericParamCount, index: count))
        }
        if count == .max {
            sig.addChild(SwiftSymbol(kind: .DependentGenericParamCount, index: 1))
        }
        if nextIf("r") { return sig }
        guard nextIf("R") else { return nil }
        while !nextIf("r") {
            guard let reqt = demangleGenericRequirement(depth + 1) else { return nil }
            sig.addChild(reqt)
        }
        return sig
    }

    private func demangleGenericRequirement(_ depth: Int) -> SwiftSymbol? {
        guard let constrainedType = demangleConstrainedType(depth + 1) else { return nil }
        if nextIf("z") {
            guard let second = demangleType(depth + 1) else { return nil }
            return SwiftSymbol(kind: .DependentGenericSameTypeRequirement, children: [constrainedType, second])
        }
        if nextIf("l") {
            return demangleLayoutRequirement(constrainedType, depth)
        }
        if isEmpty { return nil }
        let constraint: SwiftSymbol
        switch peekByte() {
        case UInt8(ascii: "C"):
            guard let c = demangleType(depth + 1) else { return nil }
            constraint = c
        case UInt8(ascii: "S"):
            advance(1)
            guard let sub = demangleSubstitutionIndex(depth + 1) else { return nil }
            let typeName: SwiftSymbol
            if sub.kind == .protocolNode || sub.kind == .Class {
                typeName = sub
            } else if sub.kind == .Module {
                guard let t = demangleProtocolNameGivenContext(sub, depth + 1) else { return nil }
                typeName = t
            } else {
                return nil
            }
            constraint = SwiftSymbol(kind: .`Type`, child: typeName)
        default:
            guard let c = demangleProtocolName(depth + 1) else { return nil }
            constraint = c
        }
        return SwiftSymbol(kind: .DependentGenericConformanceRequirement, children: [constrainedType, constraint])
    }

    private func demangleLayoutRequirement(_ constrainedType: SwiftSymbol, _: Int) -> SwiftSymbol? {
        var size: UInt64?
        var alignment: UInt64?
        let name: String
        if nextIf("U") { name = "U" }
        else if nextIf("R") { name = "R" }
        else if nextIf("N") { name = "N" }
        else if nextIf("T") { name = "T" }
        else if nextIf("B") { name = "B" }
        else if nextIf("E") {
            guard let s = demangleNatural(), nextIf("_"), let a = demangleNatural() else { return nil }
            size = s; alignment = a; name = "E"
        } else if nextIf("e") {
            guard let s = demangleNatural() else { return nil }; size = s; name = "e"
        } else if nextIf("M") {
            guard let s = demangleNatural(), nextIf("_"), let a = demangleNatural() else { return nil }
            size = s; alignment = a; name = "M"
        } else if nextIf("m") {
            guard let s = demangleNatural() else { return nil }; size = s; name = "m"
        } else if nextIf("S") {
            guard let s = demangleNatural() else { return nil }; size = s; name = "S"
        } else {
            return nil
        }
        var reqt = SwiftSymbol(kind: .DependentGenericLayoutRequirement, children: [
            constrainedType, SwiftSymbol(kind: .Identifier, name: name),
        ])
        if let size {
            reqt.addChild(SwiftSymbol(kind: .Number, index: size))
            if let alignment { reqt.addChild(SwiftSymbol(kind: .Number, index: alignment)) }
        }
        return reqt
    }

    // MARK: Archetypes, tuples

    private func demangleArchetypeType(_ depth: Int) -> SwiftSymbol? {
        func makeAssociatedType(_ root: SwiftSymbol) -> SwiftSymbol? {
            guard let name = demangleIdentifier(depth + 1) else { return nil }
            let assoc = SwiftSymbol(kind: .AssociatedTypeRef, children: [root, name])
            substitutions.append(assoc)
            return assoc
        }
        if nextIf("Q") {
            guard let root = demangleArchetypeType(depth + 1) else { return nil }
            return makeAssociatedType(root)
        }
        if nextIf("S") {
            guard let sub = demangleSubstitutionIndex(depth + 1) else { return nil }
            return makeAssociatedType(sub)
        }
        if nextIf("s") {
            return makeAssociatedType(SwiftSymbol(kind: .Module, name: SwiftManglingConstants.stdlibName))
        }
        return nil
    }

    private func demangleTuple(variadic: Bool, _ depth: Int) -> SwiftSymbol? {
        var tuple = SwiftSymbol(kind: .Tuple)
        var lastIndex: Int?
        while !nextIf("_") {
            if isEmpty { return nil }
            var elt = SwiftSymbol(kind: .TupleElement)
            if Self.isStartOfIdentifier(peekByte()) {
                guard let label = demangleIdentifier(depth + 1, kind: .TupleElementName) else { return nil }
                elt.addChild(label)
            }
            guard let type = demangleType(depth + 1) else { return nil }
            elt.addChild(type)
            tuple.addChild(elt)
            lastIndex = tuple.children.count - 1
        }
        if variadic, let lastIndex {
            var elt = tuple.children[lastIndex]
            elt.children.insert(SwiftSymbol(kind: .VariadicMarker), at: 0)
            tuple.children[lastIndex] = elt
        }
        return tuple
    }

    // MARK: Types

    private func demangleType(_ depth: Int) -> SwiftSymbol? {
        guard let type = demangleTypeImpl(depth) else { return nil }
        return SwiftSymbol(kind: .`Type`, child: type)
    }

    private func demangleFunctionType(_ kind: SwiftSymbol.Kind, _ depth: Int) -> SwiftSymbol? {
        var throwsAnnotation = false, concurrent = false, async = false
        var diffKind: UInt8 = 0
        var globalActorType: SwiftSymbol?
        if !isEmpty {
            throwsAnnotation = nextIf("z")
            concurrent = nextIf("y")
            async = nextIf("Z")
            if nextIf("D") {
                let k = nextByte()
                switch k {
                case UInt8(ascii: "f"), UInt8(ascii: "r"), UInt8(ascii: "d"), UInt8(ascii: "l"): diffKind = k
                default: break
                }
            }
            if nextIf("Y") {
                guard let g = demangleType(depth + 1) else { return nil }
                globalActorType = g
            }
        }
        guard let inArgs = demangleType(depth + 1), let outArgs = demangleType(depth + 1) else { return nil }
        var block = SwiftSymbol(kind: kind)
        if throwsAnnotation { block.addChild(SwiftSymbol(kind: .ThrowsAnnotation)) }
        if async { block.addChild(SwiftSymbol(kind: .AsyncAnnotation)) }
        if concurrent { block.addChild(SwiftSymbol(kind: .ConcurrentFunctionType)) }
        if diffKind != 0 { block.addChild(SwiftSymbol(kind: .DifferentiableFunctionType, index: UInt64(diffKind))) }
        if let globalActorType {
            block.addChild(SwiftSymbol(kind: .GlobalActorFunctionType, child: globalActorType))
        }
        block.addChild(SwiftSymbol(kind: .ArgumentTuple, child: inArgs))
        block.addChild(SwiftSymbol(kind: .ReturnType, child: outArgs))
        return block
    }

    private func demangleTypeImpl(_ depth: Int) -> SwiftSymbol? {
        if depth > Self.maxDepth || isEmpty { return nil }
        let c = nextByte()
        switch c {
        case UInt8(ascii: "B"): return demangleBuiltinType(depth)
        case UInt8(ascii: "a"): return demangleDeclarationName(.TypeAlias, depth + 1)
        case UInt8(ascii: "b"): return demangleFunctionType(.ObjCBlock, depth + 1)
        case UInt8(ascii: "c"): return demangleFunctionType(.CFunctionPointer, depth + 1)
        case UInt8(ascii: "D"):
            return childOf(.DynamicSelf, demangleType(depth + 1))
        case UInt8(ascii: "E"):
            guard nextIf("RR") else { return nil }
            return SwiftSymbol(kind: .ErrorType, name: "")
        case UInt8(ascii: "F"): return demangleFunctionType(.FunctionType, depth + 1)
        case UInt8(ascii: "f"): return demangleFunctionType(.UncurriedFunctionType, depth + 1)
        case UInt8(ascii: "G"): return demangleBoundGenericType(depth + 1)
        case UInt8(ascii: "X"): return demangleSpecialTypeOld(depth)
        case UInt8(ascii: "K"): return demangleFunctionType(.AutoClosureType, depth + 1)
        case UInt8(ascii: "M"): return childOf(.Metatype, demangleType(depth + 1))
        case UInt8(ascii: "P"):
            if nextIf("M") { return childOf(.ExistentialMetatype, demangleType(depth + 1)) }
            return demangleProtocolList(depth + 1)
        case UInt8(ascii: "Q"):
            if nextIf("u") { return SwiftSymbol(kind: .OpaqueReturnType) }
            if nextIf("U") {
                guard let ordinal = demangleIndex() else { return nil }
                return SwiftSymbol(kind: .OpaqueReturnType, child: SwiftSymbol(kind: .OpaqueReturnTypeIndex, index: ordinal))
            }
            return demangleArchetypeType(depth + 1)
        case UInt8(ascii: "q"): return demangleDependentType(depth + 1)
        case UInt8(ascii: "x"): return getDependentGenericParamType(0, 0)
        case UInt8(ascii: "w"): return demangleAssociatedTypeSimple(depth + 1)
        case UInt8(ascii: "W"): return demangleAssociatedTypeCompound(depth + 1)
        case UInt8(ascii: "R"):
            guard let type = demangleTypeImpl(depth + 1) else { return nil }
            return SwiftSymbol(kind: .InOut, child: type)
        case UInt8(ascii: "k"):
            guard let type = demangleTypeImpl(depth + 1) else { return nil }
            return SwiftSymbol(kind: .NoDerivative, child: type)
        case UInt8(ascii: "S"): return demangleSubstitutionIndex(depth + 1)
        case UInt8(ascii: "T"): return demangleTuple(variadic: false, depth + 1)
        case UInt8(ascii: "t"): return demangleTuple(variadic: true, depth + 1)
        case UInt8(ascii: "u"):
            guard let sig = demangleGenericSignature(depth + 1), let sub = demangleType(depth + 1) else { return nil }
            return SwiftSymbol(kind: .DependentGenericType, children: [sig, sub])
        default:
            if Self.isStartOfNominalType(c) {
                return demangleDeclarationName(Self.nominalTypeMarkerToNodeKind(c), depth + 1)
            }
            return nil
        }
    }

    private func demangleBuiltinType(_: Int) -> SwiftSymbol? {
        if isEmpty { return nil }
        let c = nextByte()
        switch c {
        case UInt8(ascii: "b"): return SwiftSymbol(kind: .BuiltinTypeName, name: "Builtin.BridgeObject")
        case UInt8(ascii: "B"): return SwiftSymbol(kind: .BuiltinTypeName, name: "Builtin.UnsafeValueBuffer")
        case UInt8(ascii: "f"):
            guard let size = demangleBuiltinSize() else { return nil }
            return SwiftSymbol(kind: .BuiltinTypeName, name: "Builtin.FPIEEE\(size)")
        case UInt8(ascii: "i"):
            guard let size = demangleBuiltinSize() else { return nil }
            return SwiftSymbol(kind: .BuiltinTypeName, name: "Builtin.Int\(size)")
        case UInt8(ascii: "v"):
            guard let elts = demangleNatural(), nextIf("B") else { return nil }
            if nextIf("i") {
                guard let size = demangleBuiltinSize() else { return nil }
                return SwiftSymbol(kind: .BuiltinTypeName, name: "Builtin.Vec\(elts)xInt\(size)")
            }
            if nextIf("f") {
                guard let size = demangleBuiltinSize() else { return nil }
                return SwiftSymbol(kind: .BuiltinTypeName, name: "Builtin.Vec\(elts)xFPIEEE\(size)")
            }
            if nextIf("p") { return SwiftSymbol(kind: .BuiltinTypeName, name: "Builtin.Vec\(elts)xRawPointer") }
            return nil
        case UInt8(ascii: "O"): return SwiftSymbol(kind: .BuiltinTypeName, name: "Builtin.UnknownObject")
        case UInt8(ascii: "o"): return SwiftSymbol(kind: .BuiltinTypeName, name: "Builtin.NativeObject")
        case UInt8(ascii: "p"): return SwiftSymbol(kind: .BuiltinTypeName, name: "Builtin.RawPointer")
        case UInt8(ascii: "t"): return SwiftSymbol(kind: .BuiltinTypeName, name: "Builtin.SILToken")
        case UInt8(ascii: "w"): return SwiftSymbol(kind: .BuiltinTypeName, name: "Builtin.Word")
        default: return nil
        }
    }

    /// The `X`-introduced special types.
    private func demangleSpecialTypeOld(_ depth: Int) -> SwiftSymbol? {
        if nextIf("b") {
            guard let type = demangleType(depth + 1) else { return nil }
            return SwiftSymbol(kind: .SILBoxType, child: type)
        }
        if nextIf("B") { return demangleSILBoxTypeWithLayout(depth) }
        if nextIf("M") {
            guard let repr = demangleMetatypeRepresentation(depth + 1), let type = demangleType(depth + 1) else { return nil }
            return SwiftSymbol(kind: .Metatype, children: [repr, type])
        }
        if nextIf("P") {
            if nextIf("M") {
                guard let repr = demangleMetatypeRepresentation(depth + 1), let type = demangleType(depth + 1) else { return nil }
                return SwiftSymbol(kind: .ExistentialMetatype, children: [repr, type])
            }
            return demangleProtocolList(depth + 1)
        }
        if nextIf("f") { return demangleFunctionType(.ThinFunctionType, depth + 1) }
        if nextIf("o") { return childOf(.Unowned, demangleType(depth + 1)) }
        if nextIf("u") { return childOf(.Unmanaged, demangleType(depth + 1)) }
        if nextIf("w") { return childOf(.Weak, demangleType(depth + 1)) }
        if nextIf("F") { return demangleImplFunctionType(depth + 1) }
        return nil
    }

    private func demangleSILBoxTypeWithLayout(_ depth: Int) -> SwiftSymbol? {
        var signature: SwiftSymbol?
        if nextIf("G") {
            guard let sig = demangleGenericSignature(depth, isPseudogeneric: false) else { return nil }
            signature = sig
        }
        var layout = SwiftSymbol(kind: .SILBoxLayout)
        while !nextIf("_") {
            let fieldKind: SwiftSymbol.Kind
            if nextIf("m") { fieldKind = .SILBoxMutableField }
            else if nextIf("i") { fieldKind = .SILBoxImmutableField }
            else { return nil }
            guard let type = demangleType(depth + 1) else { return nil }
            layout.addChild(SwiftSymbol(kind: fieldKind, child: type))
        }
        var genericArgs: SwiftSymbol?
        if signature != nil {
            var args = SwiftSymbol(kind: .TypeList)
            while !nextIf("_") {
                guard let type = demangleType(depth + 1) else { return nil }
                args.addChild(type)
            }
            genericArgs = args
        }
        var boxType = SwiftSymbol(kind: .SILBoxTypeWithLayout, child: layout)
        if let signature, let genericArgs {
            boxType.addChild(signature)
            boxType.addChild(genericArgs)
        }
        return boxType
    }

    private func demangleMetatypeRepresentation(_: Int) -> SwiftSymbol? {
        if nextIf("t") { return SwiftSymbol(kind: .MetatypeRepresentation, name: "@thin") }
        if nextIf("T") { return SwiftSymbol(kind: .MetatypeRepresentation, name: "@thick") }
        if nextIf("o") { return SwiftSymbol(kind: .MetatypeRepresentation, name: "@objc_metatype") }
        return nil
    }

    // MARK: Reabstraction / impl-function

    private func demangleReabstractSignature(_ signature: inout SwiftSymbol, _ depth: Int) -> Bool {
        if nextIf("G") {
            guard let generics = demangleGenericSignature(depth + 1) else { return false }
            signature.addChild(generics)
        }
        guard let srcType = demangleType(depth + 1) else { return false }
        signature.addChild(srcType)
        guard let destType = demangleType(depth + 1) else { return false }
        signature.addChild(destType)
        return true
    }

    private enum ImplConventionContext { case callee, parameter, result }

    private func demangleImplConvention(_ ctxt: ImplConventionContext) -> String {
        func match(_ ch: String, _ callee: String, _ parameter: String, _ result: String) -> String? {
            guard nextIf(ch) else { return nil }
            switch ctxt {
            case .callee: return callee
            case .parameter: return parameter
            case .result: return result
            }
        }
        if let r = match("a", "", "", "@autoreleased") { return r }
        if let r = match("d", "@callee_unowned", "@unowned", "@unowned") { return r }
        if let r = match("D", "", "", "@unowned_inner_pointer") { return r }
        if let r = match("g", "@callee_guaranteed", "@guaranteed", "") { return r }
        if let r = match("e", "", "@deallocating", "") { return r }
        if let r = match("i", "", "@in", "@out") { return r }
        if let r = match("l", "", "@inout", "") { return r }
        if let r = match("o", "@callee_owned", "@owned", "@owned") { return r }
        return ""
    }

    private func demangleImplFunctionType(_ depth: Int) -> SwiftSymbol? {
        var type = SwiftSymbol(kind: .ImplFunctionType)
        let calleeAttr: String = if nextIf("t") { "@convention(thin)" }
        else { demangleImplConvention(.callee) }
        if calleeAttr.isEmpty { return nil }
        type.addChild(SwiftSymbol(kind: .ImplConvention, name: calleeAttr))

        if nextIf("C") {
            if nextIf("b") { addImplFunctionConvention(&type, "block") }
            else if nextIf("c") { addImplFunctionConvention(&type, "c") }
            else if nextIf("m") { addImplFunctionConvention(&type, "method") }
            else if nextIf("O") { addImplFunctionConvention(&type, "objc_method") }
            else if nextIf("w") { addImplFunctionConvention(&type, "witness_method") }
            else { return nil }
        }
        if nextIf("h") { type.addChild(SwiftSymbol(kind: .ImplFunctionAttribute, name: "@Sendable")) }
        if nextIf("H") { type.addChild(SwiftSymbol(kind: .ImplFunctionAttribute, name: "@async")) }

        var isPseudogeneric = false
        if nextIf("G") || { isPseudogeneric = nextIf("g"); return isPseudogeneric }() {
            guard let generics = demangleGenericSignature(depth + 1, isPseudogeneric: isPseudogeneric) else { return nil }
            type.addChild(generics)
        }
        guard nextIf("_") else { return nil }
        while !nextIf("_") {
            guard let input = demangleImplParameterOrResult(.ImplParameter, depth + 1) else { return nil }
            type.addChild(input)
        }
        while !nextIf("_") {
            guard let res = demangleImplParameterOrResult(.ImplResult, depth + 1) else { return nil }
            type.addChild(res)
        }
        return type
    }

    private func addImplFunctionConvention(_ parent: inout SwiftSymbol, _ attr: String) {
        parent.addChild(SwiftSymbol(kind: .ImplFunctionConvention,
                                    child: SwiftSymbol(kind: .ImplFunctionConventionName, name: attr)))
    }

    private func demangleImplParameterOrResult(_ kind0: SwiftSymbol.Kind, _ depth: Int) -> SwiftSymbol? {
        var kind = kind0
        if nextIf("z") {
            guard kind == .ImplResult else { return nil }
            kind = .ImplErrorResult
        }
        let ctxt: ImplConventionContext
        switch kind {
        case .ImplParameter: ctxt = .parameter
        case .ImplResult, .ImplErrorResult: ctxt = .result
        default: return nil
        }
        let convention = demangleImplConvention(ctxt)
        if convention.isEmpty { return nil }
        guard let type = demangleType(depth + 1) else { return nil }
        return SwiftSymbol(kind: kind, children: [SwiftSymbol(kind: .ImplConvention, name: convention), type])
    }
}
