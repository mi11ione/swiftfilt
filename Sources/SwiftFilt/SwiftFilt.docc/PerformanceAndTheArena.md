# Performance and the arena

Two node backends behind one demangler — a bump-allocated arena for the
string path, the ``SwiftSymbol`` value tree for the structured path —
driven by a single corpus-validated logic body.

## Overview

Naive demangling is allocation-bound: profiling SwiftFilt's own pre-arena
engine put memory management (`malloc`/`free`, retain/release,
copy-on-write churn) at roughly half of a demangling workload, above the
parsing logic itself. The answer is two node representations behind one
engine, each matched to what its caller needs.

The demangler and the printer are generic over a `NodeBuilder` seam: one
logic body — the productions that turn bytes into nodes, and the printer
that turns nodes into text — compiles against either backend. There is no
second parser and no second printer to drift; the two paths are the same
code, specialized twice.

## The two paths

**The string path** — ``demangle(_:style:)``, ``demangleAll(in:style:)``,
the scanner's `demangleAll(inBytes:)`, and the `swiftfilt` CLI filter —
builds nodes in a bump-allocated arena: a raw slab addressed by integer
handles, no per-node allocation, no reference counting, no copy-on-write
check on the hot path. A verbatim ASCII identifier (the majority in
real-world symbols) is carried as a range into the input and rendered
straight to the output, with no owning `String`. The printer appends UTF-8
into one reserved buffer that becomes the result `String` exactly once;
nothing escapes the call, so the arena is released wholesale on return.
The batch paths reuse the whole engine — a filter pass re-windows one
demangler/arena/printer across every candidate, and ``DemangleSession``
offers callers the same amortization, so a steady-state session demangle
allocates just twice: the input copy and the result string.

**The structured path** — ``DemangledSymbol`` and the ``SwiftSymbol`` tree
it exposes, ``MangledNameScanner/Match``, and the CLI's `--tree`/`--json`
— builds the public ``SwiftSymbol`` value tree: an inspectable,
`Sendable`, value-semantic tree you can walk, pattern-match, and keep past
the call. It pays the per-node allocation the arena avoids — by design,
because you asked for the structure, not only the text.

## One engine, validated as one

Both backends run the identical productions and the identical printer, so
they must agree byte-for-byte on every symbol in every style; any
divergence would be an arena bug, never a rendering choice. That is not
asserted but measured — the repository's parity instrument diffs the arena
backend against the ``SwiftSymbol`` backend across the full real-world
corpus, every symbol × every style, at zero mismatches, on top of the
corpus-wide parity against a live `swift-demangle` every rendering claim
already rests on (<doc:StylesAndValidation>, <doc:ScopeAndGuarantees>).

Asking for structure instead of a string is a real, reason-about-able
cost; asking for a string never trades correctness for speed — the fast
path is the same validated engine. The measured numbers and methodology
are in the repository's `Benchmarks/README.md`, a competitive card against
the incumbents: `swift-demangle`, the runtime's C++ `swift_demangle` hook,
`Runtime.demangle`, and CwlDemangle.
