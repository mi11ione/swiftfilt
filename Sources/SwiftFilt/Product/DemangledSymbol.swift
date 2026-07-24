// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

/// The structured view of one demangled Swift symbol: what it is, where it
/// lives, and every validated rendering — without node-tree spelunking.
///
/// ```swift
/// let symbol = try DemangledSymbol(parsing: "$s4main6ServerC5start4portySi_tF")
/// symbol.module        // "main"
/// symbol.path          // ["Server", "start"]
/// symbol.kind          // .function
/// symbol.description   // "main.Server.start(port: Swift.Int) -> ()"
/// symbol.identityKey   // the crash-grouping key
/// ```
///
/// The stored properties are the input and its demangling tree; every
/// curated field is computed from the tree on access (pay only for what
/// you read — cache fields yourself in hot loops over millions of
/// symbols). The full grammar remains one hop away through ``symbol``.
///
/// Equality and hashing cover the mangled name and its tree — two values
/// parsed from the same string are equal.
public struct DemangledSymbol: Sendable, Hashable, CustomStringConvertible {
    /// The mangled name this value was parsed from, byte-for-byte.
    public let mangledName: String

    /// The full demangling tree (`Global`-rooted), for everything the
    /// curated fields do not answer.
    public let symbol: SwiftSymbol

    /// Parses a mangled name, throwing the ``DemangleError`` taxonomy on
    /// failure: ``DemangleError/notSwiftMangled`` for names with no Swift
    /// mangling prefix, ``DemangleError/malformed`` for Swift-prefixed
    /// names that do not parse. Accepts every era ``demangle(_:style:)``
    /// accepts, including the Mach-O `__T…` double-underscore form. The
    /// whole name must be the mangling: linker-map and metadata rows with
    /// non-mangling wrappers (`l_$s…Hr`, `_symbolic $s…`) throw
    /// `.notSwiftMangled` here — scan those with ``MangledNameScanner``,
    /// which finds the embedded name.
    public init(parsing mangledName: String) throws(DemangleError) {
        guard let tree = ProductDemangling.demangle(mangledName) else {
            throw ProductDemangling.failureReason(mangledName)
        }
        self.mangledName = mangledName
        symbol = tree
    }

    /// Parses a mangled name, or `nil` when it does not demangle — the
    /// non-throwing twin of ``init(parsing:)``.
    public init?(_ mangledName: String) {
        guard let tree = ProductDemangling.demangle(mangledName) else { return nil }
        self.mangledName = mangledName
        symbol = tree
    }

    /// Lifts an already-built demangling tree into the curated tier without
    /// re-parsing.
    ///
    /// The bridge from ``MangledNameScanner`` — whose matches already carry
    /// the validated ``SwiftSymbol`` (``MangledNameScanner/Match/symbol``) —
    /// to ``identityKey`` and the curated fields, so a crash-grouping scan
    /// stays single-pass instead of demangling each name a second time to
    /// reach its key. `symbol` is taken as given (a `Global`-rooted tree
    /// from this library's demangler); the curated fields are computed from
    /// whatever tree is passed, with the same total, trap-free fallbacks as
    /// the parsing initializers — a mismatched tree yields the fields of the
    /// tree, never a crash.
    public init(_ symbol: SwiftSymbol, mangledName: String) {
        self.mangledName = mangledName
        self.symbol = symbol
    }

    // MARK: What it is

    /// The curated classification — see ``Kind``.
    public var kind: Kind {
        SymbolClassification.kind(of: SymbolClassification.primary(of: symbol))
    }

    /// Whether the symbol is compiler-generated machinery rather than an
    /// entity someone wrote: forwarding artifacts (every ``isThunk``
    /// carrier and ``Kind/thunk(_:)``), outlined helpers, runtime metadata
    /// records (enum case records included), and variable/default-argument
    /// initializers. Everything else — functions, accessors, closures,
    /// types, protocol declarations — counts as human-written. This is
    /// exactly `swiftfilt census`'s machinery/human headline split, so a
    /// library consumer can reproduce the census numbers.
    public var isCompilerGenerated: Bool {
        if isThunk { return true }
        switch kind {
        case .outlined, .metadata, .variableInitializer, .defaultArgument, .enumCase:
            return true
        default:
            return false
        }
    }

    /// The unmangled trailing suffix, when the name carries one — dot-glued
    /// text after the mangling body (`.stub` / `.got` linker-plumbing tags
    /// on symbol-table and LinkMap rows, `.llvm.…` local markers, macro
    /// buffer tails). `nil` when the whole name demangled. The suffix
    /// distinguishes physical atoms that share one logical identity: a
    /// function, its `.stub`, and its `.got` slot all fold to one
    /// ``identityKey`` but are three different atoms in a binary — size
    /// tooling groups by `identityKey` plus `suffix` (exactly what
    /// `swiftfilt census` does).
    public var suffix: String? {
        guard let last = symbol.children.last, last.kind == .Suffix else { return nil }
        return last.text
    }

    /// Whether the entity is `static` (or a `class` member, which mangles
    /// identically).
    public var isStatic: Bool {
        SymbolClassification.isStatic(SymbolClassification.primary(of: symbol))
    }

    /// Whether the symbol is a compiler-generated forwarding artifact:
    /// any ``Kind/thunk(_:)``, a ``Kind/protocolWitness``, or an entity
    /// carrying an `@objc`/non-ObjC bridging, distributed-thunk, or
    /// back-deployment-thunk marker.
    ///
    /// This is deliberately broader than `swift-demangle -classify`'s
    /// `{T:…}` marker in covering dispatch/curry/key-path thunks, and
    /// narrower in *not* counting every allocating initializer as a thunk;
    /// the `-classify` notion stays available via
    /// ``SwiftDemanglerPrinter/classify(_:)``.
    public var isThunk: Bool {
        switch kind {
        case .thunk, .protocolWitness: return true
        default: break
        }
        return SymbolClassification.globalAttributes(of: symbol).contains {
            switch $0.kind {
            case .ObjCAttribute, .NonObjCAttribute, .DistributedThunk, .BackDeploymentThunk:
                true
            default:
                false
            }
        }
    }

    /// Whether the symbol is a compiler-generated specialization (generic,
    /// partial, prespecialized, inlined-generic, or function-signature) of
    /// a generic origin. ``genericOrigin`` names that origin.
    public var isSpecialized: Bool {
        SymbolClassification.globalAttributes(of: symbol)
            .contains { SymbolClassification.specializationKinds.contains($0.kind) }
    }

    /// The generic origin's demangling tree — this symbol with its
    /// specialization markers removed, every other attribute intact — or
    /// `nil` when ``isSpecialized`` is false (or nothing remains). The shared
    /// derivation behind ``genericOrigin`` and ``genericOriginSymbol``; it
    /// builds no strings and re-mangles nothing, so the hot ``genericOrigin``
    /// path (the census's per-row specialization tally) is unchanged.
    private var genericOriginTree: SwiftSymbol? {
        guard isSpecialized, symbol.kind == .Global else { return nil }
        let remaining = symbol.children.filter {
            !SymbolClassification.specializationKinds.contains($0.kind)
        }
        return remaining.isEmpty ? nil : SwiftSymbol(kind: .Global, children: remaining)
    }

    /// For a specialization, the ``DemangleStyle/full`` rendering of the
    /// generic origin — the symbol with its specialization markers removed,
    /// every other attribute intact. `nil` when ``isSpecialized`` is false.
    public var genericOrigin: String? {
        guard let origin = genericOriginTree else { return nil }
        let rendered = SwiftDemanglerPrinter().print(origin, style: .full)
        return rendered.isEmpty ? nil : rendered
    }

    /// For a specialization, the generic origin lifted into the curated tier
    /// — so a consumer reads the origin's ``kind``, ``module``, ``path``,
    /// ``identityKey``, and every rendering *structurally*, instead of
    /// re-parsing the ``genericOrigin`` string. `nil` on exactly the same
    /// symbols ``genericOrigin`` is (not a specialization, or a degenerate
    /// origin that renders to nothing).
    ///
    /// The origin's ``DemangledSymbol/mangledName`` is its own canonical
    /// re-mangling — the mangled name of the *unspecialized* symbol — or,
    /// for the rare origin the remangler cannot convert, this symbol's own
    /// mangled name as a stable fallback (the curated fields read the tree,
    /// not the mangling, so they are unaffected either way).
    public var genericOriginSymbol: DemangledSymbol? {
        guard let origin = genericOriginTree else { return nil }
        guard !SwiftDemanglerPrinter().print(origin, style: .full).isEmpty else { return nil }
        let originMangled = SwiftMangler().mangle(origin) ?? mangledName
        return DemangledSymbol(origin, mangledName: originMangled)
    }

    /// The mangling scheme: ``SwiftManglingFlavor/embedded`` for Embedded
    /// Swift `$e`/`_$e` names, ``SwiftManglingFlavor/standard`` otherwise.
    public var flavor: SwiftManglingFlavor {
        mangledName.hasPrefix("$e") || mangledName.hasPrefix("_$e") ? .embedded : .standard
    }

    // MARK: Where it lives

    /// The defining module, or `nil` when the tree does not carry one
    /// statically (symbolic references, signature-only thunks).
    ///
    /// For members of extensions this is the module *defining the
    /// extension* (where the code lives), not the extended type's. For
    /// protocol witnesses it is the module of the conformance. For
    /// outlined helpers and metadata records the module is the *primary
    /// entity's* — `outlined destroy of Swift.Optional<App.Row>` reports
    /// `Swift`, because `Optional` is the subject, even though the helper
    /// is emitted into the client binary; size tooling attributing bytes
    /// per module should know that convention.
    public var module: String? {
        namingComponents.module
    }

    /// The declaration-name path from the module to the symbol's own name
    /// — `["Server", "start"]` for `main.Server.start(port:)`. Module
    /// names never appear; unnamed wrappers (closures, accessors) name the
    /// declaration they belong to; initializers and deinitializers
    /// contribute `"init"`/`"deinit"`, subscripts `"subscript"`; private
    /// and local names contribute their identifier with the discriminator
    /// left to the printed forms; protocol witnesses contribute the
    /// conforming type's path plus the requirement name; macro expansions
    /// end with the macro name. Empty when the tree carries no static
    /// names.
    public var path: [String] {
        namingComponents.path
    }

    /// The innermost *named* declaration's name (`path.last`): the method
    /// name for methods and their closures, the property name for
    /// accessors, `"init"`/`"deinit"`/`"subscript"` for those members,
    /// the type name for type and metadata symbols. `nil` when no static
    /// name exists.
    public var name: String? {
        namingComponents.path.last
    }

    /// `module` and `path` joined with `.` — `"main.Server.start"` — the
    /// dot-qualified declaration name without signature. Empty when
    /// nothing is statically named.
    public var qualifiedName: String {
        let components = namingComponents
        return ((components.module.map { [$0] } ?? []) + components.path).joined(separator: ".")
    }

    private var namingComponents: SymbolNaming.Components {
        SymbolNaming.components(of: SymbolClassification.primary(of: symbol))
    }

    // MARK: Printed forms

    /// The demangled name rendered in `style` — each of the four presets is
    /// corpus-validated against its `swift-demangle` mode. May be empty
    /// only for degenerate trees the reference printer also refuses.
    public func rendered(_ style: DemangleStyle = .full) -> String {
        SwiftDemanglerPrinter().print(symbol, style: style.printerStyle)
    }

    /// The ``DemangleStyle/full`` rendering — what plain `swift-demangle`
    /// prints.
    public var description: String {
        rendered(.full)
    }
}
