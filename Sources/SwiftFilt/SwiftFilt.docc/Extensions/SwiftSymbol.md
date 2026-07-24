# ``SwiftFilt/SwiftSymbol``

## Grammar evolution and switching policy

The node tree is a faithful mirror of Swift's mangling grammar, and that
grammar moves: every Swift release can introduce node kinds (macros, typed
throws, pack iteration, isolated deinits all arrived this way). SwiftFilt
tracks it, so new ``Kind`` cases appear in minor releases.

Treat the tree as an open vocabulary:

- Switch over ``Kind`` non-exhaustively — always provide a `default:` —
  unless you deliberately want a source break to flag every grammar
  addition for review.
- Never assume a fixed child count or child order beyond what you have
  verified for the kinds you handle; unknown kinds should flow through
  untouched.
- The curated tier (``DemangledSymbol``) absorbs grammar growth into
  stable buckets and is the right dependency when you do not need the
  raw grammar.

## Topics

### Structure

- ``SwiftSymbol/kind``
- ``SwiftSymbol/children``
- ``SwiftSymbol/contents``

### Validation surface

- ``SwiftSymbol/treeDump()``
