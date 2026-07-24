# ``SwiftFilt/SwiftSymbol/Kind``

## Grammar evolution and switching policy

Cases mirror apple/swift's `Node::Kind` one for one, in canonical ABI
spelling. New enumerators ship with Swift releases and are added here in
minor releases of this library: switch with a `default:` arm unless you
intend to opt into a source break on every grammar addition. Code that
must survive unknown kinds unchanged should treat this enum as an open
set — exactly how the engine's own printer and remangler treat it.
