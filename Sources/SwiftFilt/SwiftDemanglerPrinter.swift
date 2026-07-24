// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

/// Renders a ``SwiftSymbol`` tree to a human-readable demangled name — a
/// faithful port of apple/swift's `lib/Demangling/NodePrinter.cpp`
/// (`nodeToString`). The four ``Style`` presets mirror `swift-demangle`'s
/// output modes.
@frozen
public struct SwiftDemanglerPrinter: Sendable {
    /// A print preset, mapping to an internal `DemangleOptions` configuration.
    @frozen
    public enum Style: Sendable, Hashable {
        /// `swift-demangle` default / `-compact`: fully qualified, sugared.
        case full
        /// `-simplified`: drops modules, signatures, conformances; labels-only.
        case simplified
        /// `-no-sugar`: fully qualified, `Optional<>`/`Array<>` spelled out.
        case qualified
        /// Names only — no module/context qualification.
        case unqualified
    }

    public init() {}

    /// The demangled name for `symbol` rendered in `style`.
    public func print(_ symbol: SwiftSymbol, style: Style = .full) -> String {
        var printer = NodePrinter<SwiftSymbolBuilder>(options: PrinterOptions(style: style), nb: SwiftSymbolBuilder())
        // Reader-only wrap: the printer never consults the handle's depth
        // (its own recursion cap bounds the descent).
        printer.printRoot(DepthTrackedSymbol(symbol: symbol, depth: 1))
        return printer.takeString()
    }

    /// The `swift-demangle -classify` token string (`{N|T:target|C}`) for a
    /// mangled `name`, or `""` when no classification applies.
    public func classify(_ name: String) -> String {
        SwiftSymbolClassifier.classify(name)
    }

    /// As ``classify(_:)`` but reusing an already-computed demangle of `name`,
    /// so a caller that has demangled the symbol avoids a second demangle.
    public func classify(_ name: String, demangled: SwiftSymbol?) -> String {
        SwiftSymbolClassifier.classify(name, demangled: demangled)
    }
}

/// The `DemangleOptions` field set (apple/swift `Demangle.h`), with the presets
/// for each ``SwiftDemanglerPrinter/Style``.
struct PrinterOptions {
    var synthesizeSugarOnTypes = false
    var qualifyEntities = true
    var displayExtensionContexts = true
    var displayUnmangledSuffix = true
    var displayModuleNames = true
    var displayGenericSpecializations = true
    var displayProtocolConformances = true
    var displayWhereClauses = true
    var displayEntityTypes = true
    var shortenPartialApply = false
    var shortenThunk = false
    var shortenValueWitness = false
    var shortenArchetype = false
    var showPrivateDiscriminators = true
    var showFunctionArgumentTypes = true
    var displayDebuggerGeneratedModule = true
    var displayStdlibModule = true
    var displayObjCModule = true
    var printForTypeName = false
    var showAsyncResumePartial = true
    var showClosureSignature = true
    var displayLocalNameContexts = true
    var hidingCurrentModule = ""

    init(style: SwiftDemanglerPrinter.Style) {
        switch style {
        case .full:
            // `swift-demangle` default: the CLI forces sugar on.
            synthesizeSugarOnTypes = true
        case .qualified:
            // `-no-sugar`: defaults (sugar off, everything qualified).
            break
        case .unqualified:
            synthesizeSugarOnTypes = true
            qualifyEntities = false
        case .simplified:
            // SimplifiedUIDemangleOptions
            synthesizeSugarOnTypes = true
            displayExtensionContexts = false
            displayUnmangledSuffix = false
            displayModuleNames = false
            displayGenericSpecializations = false
            displayProtocolConformances = false
            displayWhereClauses = false
            displayEntityTypes = false
            shortenPartialApply = true
            shortenThunk = true
            shortenValueWitness = true
            shortenArchetype = true
            showPrivateDiscriminators = false
            showFunctionArgumentTypes = false
            showAsyncResumePartial = false
        }
    }

    /// Generic-parameter display name: base-26 letters with a depth suffix
    /// (apple/swift `genericParameterName`).
    func genericParameterName(depth: UInt64, index: UInt64) -> String {
        var name = ""
        var i = index
        repeat {
            name.append(Character(UnicodeScalar(UInt8(65 + (i % 26)))))
            i /= 26
        } while i != 0
        if depth != 0 {
            name += String(depth)
        }
        return name
    }
}

/// The recursive printer, generic over a ``NodeBuilder``: it reads the node
/// tree only through `nb`, so the same rendering body prints the public
/// ``SwiftSymbol`` tree today (`NodePrinter<SwiftSymbolBuilder>`) and the
/// bump-arena node. A struct: printing threads its single mutable output
/// buffer and `specializationPrefixPrinted` flag through the recursion as
/// `inout self` (mirroring the C++ `NodePrinter`'s member state), which
/// keeps the printer off the heap — no class instance per render — and its
/// field mutations statically-exclusive (the class form needed
/// `@exclusivity(unchecked)` to claw back the dynamic access pairs).
struct NodePrinter<B: NodeBuilder> {
    /// The node reader every access routes through.
    let nb: B
    /// The output accumulator is a UTF-8 byte buffer, not a growing `String`.
    /// Every `emit` appends UTF-8 bytes — identifiers/literals via
    /// `String.utf8`, numbers as ASCII decimal digits — and the buffer is
    /// decoded to a `String` exactly once at the public boundary
    /// (``takeString()``). This mirrors the reference `NodePrinter`, whose
    /// accumulator is a `std::string` the helpers append onto and whose
    /// `Printer.getStringRef().size()` / `CurrentPosition` probes are that
    /// string's byte length (ported here as `bytes.count`). Appending to a
    /// `[UInt8]` avoids `String`'s per-append grapheme-breaking and UTF-8
    /// re-validation. Byte-exactness is structural: the bytes are
    /// the exact concatenation of each emitted `String`'s UTF-8 view, which is
    /// what `String +=` stored, so decoding reproduces the same bytes.
    var bytes: [UInt8] = []
    var options: PrinterOptions
    var isValid = true
    var specializationPrefixPrinted = false

    enum TypePrinting { case noType, withColon, functionStyle }

    init(options: PrinterOptions, nb: B) {
        self.options = options
        self.nb = nb
        // One up-front reservation sized for the common demangled name, so the
        // typical render never reallocates; longer outputs grow geometrically.
        bytes.reserveCapacity(128)
    }

    /// Rewind for another render, keeping the byte buffer's storage — the
    /// batch (session/scanner) path prints every symbol through one printer
    /// with no per-symbol allocation. Resets exactly the stored properties
    /// above (extensions cannot add storage, so the list is complete);
    /// `options` is restored whole because printing mutates option fields
    /// in place (`printForTypeName`, `displayWhereClauses`).
    mutating func reset(options: PrinterOptions) {
        bytes.removeAll(keepingCapacity: true)
        self.options = options
        isValid = true
        specializationPrefixPrinted = false
    }

    mutating func printRoot(_ root: B.Node) {
        _ = print(root, depth: 0)
    }

    /// Decode the accumulated UTF-8 bytes to a `String` — the single decode at
    /// the public boundary. Every appended run is a valid-UTF-8 `String.utf8`
    /// slice (or ASCII digits), so the concatenation is valid UTF-8 and this
    /// round-trips losslessly to the exact bytes the old `String` accumulator
    /// returned.
    func takeString() -> String {
        isValid ? String(decoding: bytes, as: UTF8.self) : ""
    }

    // MARK: emit helpers

    @inline(__always) mutating func emit(_ s: String) {
        bytes.append(contentsOf: s.utf8)
    }

    @inline(__always) mutating func emit(_ n: UInt64) {
        // `String(n)` is the heap-free small-string decimal form for every
        // value up to 15 digits; appending its UTF-8 yields the exact bytes
        // `text += String(n)` produced, without a growing-`String` accumulator.
        bytes.append(contentsOf: String(n).utf8)
    }

    /// Emit `node`'s text verbatim — the zero-copy identifier/module render seam:
    /// the arena backend appends an input-range identifier's bytes
    /// straight from the input buffer with no `String`, while owned text and the
    /// value backend append their UTF-8. Byte-for-byte equal to
    /// `emit(nb.text(of: node) ?? "")`, which every pure-passthrough text site
    /// used before; the printer's transforming/interpolating text sites still go
    /// through `nb.text(of:)`.
    @inline(__always) mutating func emitText(of node: B.Node) {
        nb.appendText(of: node, to: &bytes)
    }

    mutating func setInvalid() {
        isValid = false
    }

    func subPrint(_ node: B.Node) -> String {
        var sub = NodePrinter<B>(options: options, nb: nb)
        _ = sub.print(node, depth: 0)
        return sub.takeString()
    }

    func demangleSymbolAsString(_ mangled: String) -> String {
        // Matches the reference `demangleSymbolAsString`, which renders nested
        // names (e.g. a specialization's constant-prop payload) with the default
        // options — fully qualified, no sugar — regardless of the outer style.
        // The nested demangle comes back as a public `SwiftSymbol`, so it prints
        // through a concrete `NodePrinter<SwiftSymbolBuilder>` independent of the
        // outer node representation.
        guard let node = SwiftDemangler().demangle(symbol: mangled) else { return "" }
        // Silent skip, never silent guess: only present a nested demangling
        // this library can faithfully reproduce. The toolchain prints such an
        // embedded name raw when its own demangle is not self-consistent; mirror
        // that by requiring the name to round-trip (byte-exact, or
        // canonical-normalized) before using the demangled form — otherwise the
        // caller emits the raw mangled name.
        let remangled = SwiftMangler().mangle(node)
        if remangled != mangled {
            guard let rt = remangled,
                  SwiftDemangler().demangle(symbol: rt)?.treeDump() == node.treeDump()
            else { return "" }
        }
        var printer = NodePrinter<SwiftSymbolBuilder>(options: PrinterOptions(style: .qualified), nb: SwiftSymbolBuilder())
        _ = printer.print(DepthTrackedSymbol(symbol: node, depth: 1), depth: 0)
        return printer.takeString()
    }

    func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\"": out += "\\\""
            case "\0": out += "\\0"
            default:
                let c = scalar.value
                if c < 0x20 || c >= 0x7F {
                    let hex = Array("0123456789ABCDEF")
                    out += "\\x"
                    out.append(hex[Int((c >> 4) & 0xF)])
                    out.append(hex[Int(c & 0xF)])
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    // MARK: shared helpers

    /// Print every child of `node` in order, separated by `separator`. The
    /// reference walks the child list directly; reading by index keeps the
    /// traversal representation-agnostic (a value tree and an arena both answer
    /// `childCount`/`child(at:)` without materializing a list).
    mutating func printChildren(_ node: B.Node, depth: Int, separator: String? = nil) {
        let count = nb.childCount(of: node)
        var first = true
        for i in 0 ..< count {
            if !first, let separator { emit(separator) }
            first = false
            _ = print(nb.child(of: node, at: i), depth: depth + 1)
        }
    }

    func child(_ node: B.Node, _ index: Int) -> B.Node? {
        index >= 0 && index < nb.childCount(of: node) ? nb.child(of: node, at: index) : nil
    }

    func childIf(_ node: B.Node, _ kind: SwiftSymbol.Kind) -> B.Node? {
        for i in 0 ..< nb.childCount(of: node) {
            let c = nb.child(of: node, at: i)
            if nb.kind(of: c) == kind { return c }
        }
        return nil
    }

    func isSwiftModule(_ node: B.Node) -> Bool {
        nb.kind(of: node) == .Module && nb.textEquals(node, SwiftManglingConstants.stdlibName)
    }

    func isIdentifier(_ node: B.Node?, _ name: String) -> Bool {
        guard let node else { return false }
        return nb.kind(of: node) == .Identifier && nb.textEquals(node, name)
    }

    func isExistentialType(_ node: B.Node) -> Bool {
        switch nb.kind(of: node) {
        case .ExistentialMetatype, .ProtocolList, .ProtocolListWithClass, .ProtocolListWithAnyObject: true
        default: false
        }
    }

    func isClassType(_ node: B.Node) -> Bool {
        nb.kind(of: node) == .Class
    }

    func needSpaceBeforeType(_ type: B.Node) -> Bool {
        switch nb.kind(of: type) {
        case .`Type`: needSpaceBeforeType(nb.firstChild(of: type) ?? type)
        case .FunctionType, .NoEscapeFunctionType, .UncurriedFunctionType, .DependentGenericType: false
        default: true
        }
    }

    func shouldShowEntityType(_ kind: SwiftSymbol.Kind) -> Bool {
        switch kind {
        case .ExplicitClosure, .ImplicitClosure: options.showClosureSignature
        default: true
        }
    }

    mutating func printContext(_ context: B.Node) -> Bool {
        guard options.qualifyEntities else { return false }
        if nb.kind(of: context) == .Module {
            // Seam probes instead of one `text(of:) ?? ""` materialization —
            // the arena backend answers each from bytes with no `String`.
            // Same constants, same order, same `?? ""` semantics per check.
            if nb.textEquals(context, SwiftManglingConstants.stdlibName) { return options.displayStdlibModule }
            if nb.textEquals(context, SwiftManglingConstants.objCModule) { return options.displayObjCModule }
            if nb.textEqualsOrEmpty(context, options.hidingCurrentModule) { return false }
            if nb.textHasPrefix(context, SwiftManglingConstants.lldbExpressionsModulePrefix) { return options.displayDebuggerGeneratedModule }
        }
        return true
    }

    mutating func printOptionalIndex(_ node: B.Node) {
        if let i = nb.index(of: node) { emit("#"); emit(i); emit(" ") }
    }

    mutating func printWithParens(_ type: B.Node, depth: Int) {
        let needsParens = !isSimpleType(type)
        if needsParens { emit("(") }
        _ = print(type, depth: depth + 1)
        if needsParens { emit(")") }
    }

    func isSimpleType(_ node: B.Node) -> Bool {
        switch nb.kind(of: node) {
        case .AssociatedType, .AssociatedTypeRef, .BoundGenericClass, .BoundGenericEnum,
             .BoundGenericStructure, .BoundGenericProtocol, .BoundGenericOtherNominalType,
             .BoundGenericTypeAlias, .BoundGenericFunction, .BuiltinTypeName, .BuiltinTupleType,
             .BuiltinFixedArray, .BuiltinBorrow, .Class, .DependentGenericType, .DependentMemberType,
             .DependentGenericParamType, .DynamicSelf, .Enum, .ErrorType, .ExistentialMetatype,
             .Metatype, .MetatypeRepresentation, .Module, .Tuple, .Pack, .SILPackDirect, .SILPackIndirect,
             .ConstrainedExistentialRequirementList, .ConstrainedExistentialSelf, .protocolNode,
             .ProtocolSymbolicReference, .ReturnType, .SILBoxType, .SILBoxTypeWithLayout, .Structure,
             .OtherNominalType, .TupleElementName, .TypeAlias, .TypeList, .LabelList,
             .TypeSymbolicReference, .SugaredOptional, .SugaredArray, .SugaredInlineArray,
             .SugaredDictionary, .SugaredParen, .Integer, .NegativeInteger:
            true
        case .`Type`:
            isSimpleType(nb.firstChild(of: node) ?? node)
        case .ProtocolList:
            (nb.firstChild(of: node).map { nb.childCount(of: $0) } ?? 0) <= 1
        case .ProtocolListWithAnyObject:
            (nb.firstChild(of: node).flatMap { nb.firstChild(of: $0) }.map { nb.childCount(of: $0) } ?? 1) == 0
        default:
            false
        }
    }

    mutating func printBoundGenericNoSugar(_ node: B.Node, depth: Int) {
        guard nb.childCount(of: node) >= 2 else { return }
        _ = print(nb.child(of: node, at: 0), depth: depth + 1)
        emit("<")
        printChildren(nb.child(of: node, at: 1), depth: depth, separator: ", ")
        emit(">")
    }

    enum SugarType { case none, optional, implicitlyUnwrappedOptional, array, dictionary }

    func findSugar(_ node: B.Node) -> SugarType {
        if nb.childCount(of: node) == 1, nb.kind(of: node) == .`Type` { return findSugar(nb.child(of: node, at: 0)) }
        guard nb.childCount(of: node) == 2 else { return .none }
        guard nb.kind(of: node) == .BoundGenericEnum || nb.kind(of: node) == .BoundGenericStructure else { return .none }
        guard let unbound = nb.firstChild(of: nb.child(of: node, at: 0)) else { return .none }
        let typeArgs = nb.child(of: node, at: 1)
        if nb.kind(of: node) == .BoundGenericEnum {
            if isIdentifier(child(unbound, 1), "Optional"), nb.childCount(of: typeArgs) == 1,
               let m = nb.firstChild(of: unbound), isSwiftModule(m) { return .optional }
            if isIdentifier(child(unbound, 1), "ImplicitlyUnwrappedOptional"), nb.childCount(of: typeArgs) == 1,
               let m = nb.firstChild(of: unbound), isSwiftModule(m) { return .implicitlyUnwrappedOptional }
            return .none
        }
        if isIdentifier(child(unbound, 1), "Array"), nb.childCount(of: typeArgs) == 1,
           let m = nb.firstChild(of: unbound), isSwiftModule(m) { return .array }
        if isIdentifier(child(unbound, 1), "Dictionary"), nb.childCount(of: typeArgs) == 2,
           let m = nb.firstChild(of: unbound), isSwiftModule(m) { return .dictionary }
        return .none
    }

    mutating func printBoundGeneric(_ node: B.Node, depth: Int) {
        guard nb.childCount(of: node) >= 2 else { return }
        if nb.childCount(of: node) != 2 { printBoundGenericNoSugar(node, depth: depth); return }
        if !options.synthesizeSugarOnTypes || nb.kind(of: node) == .BoundGenericClass {
            printBoundGenericNoSugar(node, depth: depth); return
        }
        if nb.kind(of: node) == .BoundGenericProtocol {
            printChildren(nb.child(of: node, at: 1), depth: depth)
            emit(" as ")
            _ = print(nb.child(of: node, at: 0), depth: depth + 1)
            return
        }
        let sugar = findSugar(node)
        switch sugar {
        case .none: printBoundGenericNoSugar(node, depth: depth)
        case .optional, .implicitlyUnwrappedOptional:
            if let type = child(nb.child(of: node, at: 1), 0) {
                printWithParens(type, depth: depth)
                emit(sugar == .optional ? "?" : "!")
            }
        case .array:
            if let type = child(nb.child(of: node, at: 1), 0) { emit("["); _ = print(type, depth: depth + 1); emit("]") }
        case .dictionary:
            if let k = child(nb.child(of: node, at: 1), 0), let v = child(nb.child(of: node, at: 1), 1) {
                emit("["); _ = print(k, depth: depth + 1); emit(" : "); _ = print(v, depth: depth + 1); emit("]")
            }
        }
    }
}
