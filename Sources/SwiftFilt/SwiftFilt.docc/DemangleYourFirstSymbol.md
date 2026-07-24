# Demangle your first symbol

One line from a mangled name to a readable one, and a tour of the entry
points.

## Overview

The smallest entry point is ``demangle(_:style:)``: one mangled name in,
one demangled string out (or `nil`).

```swift
import SwiftFilt

demangle("$s4main3fooyyF")          // "main.foo() -> ()"
demangle("not a symbol")            // nil
```

It accepts every shipped mangling era — stable-ABI `$s`/`$S`, Embedded
Swift `$e`, Swift 4 `_T0`, the legacy Swift ≤3 `_T` grammar (including the
`_Tt` names Objective-C metadata carries), and macro-expansion
`@__swiftmacro_` names — each with or without the Mach-O leading
underscore:

```swift
demangle("_$s4main6ServerC5start4portySi_tF")
// "main.Server.start(port: Swift.Int) -> ()"

demangle("_TtC9AppModule11AppDelegate")
// "AppModule.AppDelegate"
```

`style` selects one of four validated presets; the default
``DemangleStyle/full`` matches plain `swift-demangle`
(<doc:StylesAndValidation>).

## When you need to know why

``demangle(_:style:)`` folds two different failures into `nil`: the name
is not Swift at all, or it claims to be Swift and is corrupt. Pipelines
handle those differently — a non-Swift name goes to the next demangler
(C++, Rust); a malformed Swift name has nothing left to try.
``demangle(validating:style:)`` throws the distinction as a typed
``DemangleError``:

```swift
do {
    let name = try demangle(validating: candidate)
    show(name)
} catch DemangleError.notSwiftMangled {
    show(cxxFilt(candidate) ?? candidate)   // hand it to the next demangler
} catch {
    show(candidate)                         // corrupt Swift name: show it raw
}
```

``isSwiftMangled(_:)`` is the fast prefix-only pre-filter for skipping the
demangle cost on the non-Swift majority of a symbol table; the
authoritative answer is still whether ``demangle(_:style:)`` returns
non-`nil`.

## Beyond a string

When you need to know *what* the symbol is — its kind, module, path,
whether it is a thunk or a specialization — parse a ``DemangledSymbol``
(<doc:TheStructuredSymbol>):

```swift
let symbol = try DemangledSymbol(parsing: "$s4main6ServerC5start4portySi_tF")
symbol.module          // "main"
symbol.path            // ["Server", "start"]
symbol.kind            // .function
```

And when mangled names are embedded in text — a crash log, `nm` output, a
build log — ``demangleAll(in:style:)`` rewrites them in place
(<doc:ScanningArbitraryText>):

```swift
demangleAll(in: "0  MyApp  0x104abc123 $s4main3fooyyF + 12")
// "0  MyApp  0x104abc123 main.foo() -> () + 12"
```

## A note on inputs

Demangling is total: any string either demangles or returns `nil`/throws
— never a crash, never a hang, never a partial guess
(<doc:ScopeAndGuarantees>). Inputs are never executed and never treated as
paths; a mangled name is just text.
