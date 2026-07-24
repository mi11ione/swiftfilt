# The structured symbol

`DemangledSymbol` answers what a symbol *is* and where it *lives* as
typed fields, without node-tree spelunking.

## Overview

Most demanglers stop at a string, and every pipeline downstream re-parses
that string with regexes — to pull out the module, spot a thunk, group
crash frames. ``DemangledSymbol`` is the structured alternative: parse
once, read typed fields computed from the demangling tree.

```swift
let symbol = try DemangledSymbol(parsing: "$s4main6ServerC5start4portySi_tF")
symbol.module          // "main"
symbol.path            // ["Server", "start"]
symbol.name            // "start"
symbol.qualifiedName   // "main.Server.start"
symbol.kind            // .function
symbol.isStatic        // false
symbol.description     // "main.Server.start(port: Swift.Int) -> ()"
```

``DemangledSymbol/init(parsing:)`` throws the ``DemangleError`` taxonomy;
the `init?(_:)` twin returns `nil`. Curated fields are computed on access,
so you pay only for what you read (cache them in hot loops over millions
of symbols).

## The kind taxonomy

``DemangledSymbol/kind`` classifies the symbol's *primary entity* into
the vocabulary users of symbols think in, not the raw grammar's:

| ``DemangledSymbol/Kind`` | what it covers |
| --- | --- |
| `function` | functions, methods, operators |
| `initializer` | allocating/initializing entries, ObjC ivar initializers |
| `deinitializer` | `deinit` flavors, isolated deinits, ivar destroyers |
| `accessor(AccessorKind)` | getters, setters, observers, coroutine and addressor accessors (the payload says which of the 21) |
| `variable` | the variable reference itself, not its accessors |
| `subscriptDeclaration` | the subscript declaration itself |
| `closure` | explicit and implicit closures |
| `variableInitializer` | initial-value expressions, property-wrapper backing initializers, one-time globals |
| `defaultArgument` | default-argument generators |
| `type` | any symbol denoting a type (including ObjC's `_Tt…` names) |
| `enumCase` | per-case tag records |
| `protocolDeclaration` | the protocol itself |
| `protocolWitness` | per-conformance witness entries |
| `thunk(ThunkKind)` | forwarding functions (reabstraction, curry, dispatch, key-path, partial-apply, vtable, ObjC-async, identity, autodiff) |
| `outlined` | compiler-outlined helpers |
| `macro` | macro declarations and `@__swiftmacro_` expansion artifacts |
| `metadata(MetadataKind)` | runtime records (type metadata, descriptors, conformances, value witnesses, reflection) |
| `other` | rare grammar corners; the full tree remains available |

Global *attributes* — specialization markers, `@objc` bridging,
back-deployment — deliberately do not change the kind: a specialized
`@objc` method still classifies as `function`, and the attributes surface
as ``DemangledSymbol/isSpecialized`` and ``DemangledSymbol/isThunk``. For
a specialization, ``DemangledSymbol/genericOrigin`` renders the
unspecialized origin, and ``DemangledSymbol/genericOriginSymbol`` lifts it
into its own ``DemangledSymbol`` — so its ``DemangledSymbol/kind``,
``DemangledSymbol/module``, ``DemangledSymbol/path``, and
``DemangledSymbol/identityKey`` read structurally, with no re-parsing.

New cases can appear as the grammar grows: switch with a `default:` unless
you intend to opt into a source break on library updates.

## Where a symbol lives

``DemangledSymbol/module`` is the *defining* module — for extension
members the module defining the extension, not the extended type's; for
protocol witnesses the conformance's module. ``DemangledSymbol/path`` is
the declaration-name path from the module to the symbol's own name, with
documented conventions for unnamed wrappers (closures name their enclosing
declaration, initializers contribute `"init"`, subscripts `"subscript"`,
macro expansions end with the macro name). Both are `nil`/empty when the
tree carries no static names — never a guess.

## The full grammar, one hop away

Everything the curated fields do not answer is on
``DemangledSymbol/symbol``, the full `Global`-rooted ``SwiftSymbol`` node
tree — the same shape apple/swift's demangler produces, with
``SwiftSymbol/kind``, ``SwiftSymbol/children``, and
``SwiftSymbol/contents``. The node tier (``SwiftDemangler``,
``SwiftDemanglerPrinter``, ``SwiftMangler``) is public API under the
open-vocabulary switching policy documented on ``SwiftSymbol/Kind``.
