// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// The identity key: one canonical, deterministic string per *logical
// function*, computed on the demangling tree instead of the regexes over
// printed names that crash pipelines hand-roll today.

public extension DemangledSymbol {
    /// A canonical, deterministic key identifying the *logical function* a
    /// symbol belongs to — the crash-grouping primitive.
    ///
    /// Two symbols share a key exactly when they are compiler-generated
    /// variants of the same source-level code. The key is computed
    /// structurally, on the demangling tree:
    ///
    /// **What collapses into one key.**
    /// - *Specializations*: every generic/function-signature specialization
    ///   (`…Tg5`, `…Tp5q`, inlined-generic `Ti`, prespecialized, partial,
    ///   resilience-domain) keys as its unspecialized generic origin — so
    ///   `foo<Int>` instantiations, `foo<String>` instantiations, and the
    ///   unspecialized `foo` all group.
    /// - *Async partials*: the `TQn_`/`TYn_` await-resume and
    ///   suspend-resume partial functions of an `async` function key as the
    ///   function itself, as do LLVM `.resume.N`-style suffixed pieces
    ///   (any mangling suffix is dropped).
    /// - *Dispatch-flavor annotations of the same declaration*: `@objc`
    ///   bridging (`To`) and non-ObjC (`TO`) markers, dynamic/direct
    ///   dispatch markers, vtable attributes, merged-function markers
    ///   (`Tm`), outlined per-function artifacts (`Tv`, read-only objects,
    ///   bridged methods), dynamic-replacement machinery (`TI`/`TX`/`Tx`),
    ///   async/coro function-pointer records (`Tu`), accessible-function
    ///   records, `#_hasSymbol` queries, default-override markers, and
    ///   distributed thunk/accessor markers all drop, keying as the
    ///   underlying declaration.
    /// - *Back deployment*: the `Twb` thunk and `TwB` fallback copy key as
    ///   the original function.
    /// - *Forwarding thunks whose full target is embedded in the mangling*:
    ///   partial-apply forwarders (`TA`/`Ta`), curry thunks (`Tc`),
    ///   dispatch thunks (`Tj`), and SIL identity thunks unwrap to their
    ///   target — a crash in the forwarder groups with the closure or
    ///   method it forwards to.
    /// - *Entry-point flavors of one initializer or deinitializer*: the
    ///   allocating `__allocating_init` (`fC`) keys as its `init` (`fc`) —
    ///   the same target derivation `swift-demangle -classify` performs —
    ///   and the deallocating / isolated-deallocating `deinit` flavors
    ///   (`fD`/`fZ`) key as the plain `deinit` (`fd`): each pair is one
    ///   source-level declaration.
    ///
    /// **What deliberately keeps its own key.**
    /// - *Protocol witnesses*: a witness is per-conformance code. Collapsing
    ///   it into the protocol requirement would merge every conforming
    ///   type's witnesses into one bucket, and collapsing it into the
    ///   concrete method would guess at a symbol the mangling does not
    ///   carry (for defaulted requirements no such method even exists).
    ///   The engine's invariant is "silent skip, never silent guess", so a
    ///   witness keys as itself: conforming type + protocol + requirement.
    /// - *Reabstraction thunks*: their mangling carries only the two
    ///   function signatures, never a target, so they key as themselves.
    /// - *Key-path thunk helpers, vtable thunks, ObjC async
    ///   completion-handler shims, outlined value-witness helpers*: each is
    ///   genuinely distinct executable code, not a duplicate of its
    ///   subject; merging a key-path getter helper into the property's own
    ///   getter would conflate two different functions.
    /// - *Accessors*: a getter and a setter of one property are different
    ///   code and keep different keys.
    /// - *Overloads*: argument labels and types stay in the key, so
    ///   `foo(_: Int)` and `foo(_: String)` never merge.
    ///
    /// **Printed form.** `rawValue` is the ``DemangleStyle/qualified``
    /// (no-sugar, fully-qualified — the most canonical validated preset)
    /// rendering of the normalized tree, e.g.
    /// `Accelerate.BNNS.arrayToTuple(_: Swift.Array<A>, fillValue: A) -> (A, A, A, A, A, A, A, A)`
    /// for every specialization of that function. Private-declaration
    /// discriminators are included (two private `foo`s in different files
    /// stay distinct). For the degenerate manglings that normalize or
    /// render to nothing, the key falls back to the un-normalized
    /// rendering, then to the mangled name itself — a demangleable symbol
    /// never produces an empty key.
    ///
    /// **Stability.** The key is deterministic: one input, one key, on
    /// every run. Compare keys produced by the same SwiftFilt version;
    /// across versions the grammar (and thus spellings) can evolve, so
    /// persisted keys should be re-derived rather than assumed eternal.
    struct IdentityKey: Sendable, Hashable, CustomStringConvertible {
        /// The canonical printed key (see the type documentation for the
        /// exact form).
        public let rawValue: String

        public var description: String {
            rawValue
        }
    }

    /// The identity key for this symbol's logical function — see
    /// ``IdentityKey`` for the exact grouping semantics.
    var identityKey: IdentityKey {
        IdentityKey(rawValue: SymbolIdentity.key(for: symbol, mangledName: mangledName))
    }
}

/// Tree normalization behind ``DemangledSymbol/IdentityKey``.
enum SymbolIdentity {
    /// The canonical key string: the `.qualified` rendering of
    /// ``normalized(_:)``, with the documented non-empty fallback chain.
    static func key(for root: SwiftSymbol, mangledName: String) -> String {
        let printer = SwiftDemanglerPrinter()
        let normalizedForm = printer.print(normalized(root), style: .qualified)
        if !normalizedForm.isEmpty { return normalizedForm }
        // A tree that renders to nothing (bare pack markers, degenerate
        // label-list type manglings): fall back to the un-normalized
        // rendering, then to the mangled name — never an empty key for a
        // parsed symbol. (`normalized` hands back the root itself when
        // stripping would leave nothing, so today both renderings are
        // empty together and the mangled name answers.)
        var key = printer.print(root, style: .qualified)
        if key.isEmpty { key = mangledName }
        return key
    }

    /// The identity-normalized tree: global attributes and suffixes
    /// dropped, target-embedding forwarders unwrapped. Trees that would
    /// normalize to nothing (attribute-only globals) pass through
    /// unchanged. Domain: `Global` roots — ``demangle(symbol:)`` yields
    /// nothing else (both grammars fail a parse that would not produce
    /// one), so the walk needs no non-`Global` escape.
    static func normalized(_ root: SwiftSymbol) -> SwiftSymbol {
        var kept: [SwiftSymbol] = []
        for child in root.children {
            if child.kind == .Suffix { continue }
            // Every global function attribute except the forwarders (which
            // carry their target and unwrap below) drops: specializations,
            // dispatch-flavor markers, per-function records, async
            // partials, back-deployment, distributed markers. Sharing the
            // engine's attribute predicate keeps this in sync with the
            // grammar.
            if DemanglerPredicates.isFunctionAttr(child.kind),
               child.kind != .PartialApplyForwarder, child.kind != .PartialApplyObjCForwarder
            {
                continue
            }
            kept.append(unwrapped(child))
        }
        guard !kept.isEmpty else { return root }
        return SwiftSymbol(kind: .Global, children: kept)
    }

    /// Unwraps target-embedding forwarding thunks to their target entity,
    /// recursively (a dispatch thunk of a curry thunk unwraps twice), and
    /// canonicalizes entry-point flavors onto their source declaration.
    /// No `Type` shell can reach this walk: `demangleSymbol` sheds them
    /// at both the global and the forwarder level, and the curry /
    /// dispatch / identity thunk operands are entities by construction.
    private static func unwrapped(_ node: SwiftSymbol) -> SwiftSymbol {
        switch node.kind {
        // The forwarder's target is its last child; earlier children
        // are attributes that attached to the forwarder (dropped here
        // for the same reason global attributes drop). A bare forwarder
        // (`$sTA` parses) is its own target.
        case .PartialApplyForwarder, .PartialApplyObjCForwarder:
            var target = node
            if let inner = node.children.last { target = unwrapped(inner) }
            return target
        case .CurryThunk, .DispatchThunk, .SILThunkIdentity:
            var target = node
            if let inner = node.firstChild { target = unwrapped(inner) }
            return target
        // Allocating init -> init (the `-classify` fC -> fc target);
        // deallocating / isolated deinit -> deinit. Children are
        // identical across the flavors, only the kind differs.
        case .Allocator:
            return node.changingKind(to: .Constructor)
        case .Deallocator, .IsolatedDeallocator:
            return node.changingKind(to: .Destructor)
        default:
            return node
        }
    }
}
