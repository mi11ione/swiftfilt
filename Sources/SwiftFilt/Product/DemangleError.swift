// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

/// Why a name could not be demangled — the two failure classes a caller
/// handles differently.
///
/// Thrown by ``demangle(validating:style:)`` and
/// ``DemangledSymbol/init(parsing:)``. The distinction that matters in
/// symbol pipelines: a ``notSwiftMangled`` name should be handed to the
/// *next* demangler in line (C++, Rust, …) or shown raw, while a
/// ``malformed`` name claims to be Swift and can only be corrupt or
/// truncated — there is nothing else to try.
public enum DemangleError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The input carries no Swift mangling prefix (`$s`, `$S`, `$e`, `_T0`,
    /// the legacy `_T` operators, `@__swiftmacro_`, with or without the
    /// Mach-O leading underscore). It is not a Swift symbol at all — try
    /// other demanglers or pass it through untouched.
    case notSwiftMangled

    /// The input starts like a Swift mangled name but the grammar parse
    /// failed — a corrupt, truncated, or non-symbol string wearing a Swift
    /// prefix (`"$s"` alone, a symbol cut mid-identifier, a `_T…` C symbol
    /// that slipped past prefix heuristics). Retrying other demanglers is
    /// pointless; the honest presentation is the raw string.
    case malformed

    public var description: String {
        switch self {
        case .notSwiftMangled: "not a Swift mangled name (no recognized mangling prefix)"
        case .malformed: "malformed Swift mangling (recognized prefix, but the name does not parse)"
        }
    }

    /// A short, stable machine code for this failure class —
    /// `"notSwiftMangled"` or `"malformed"` — for structured logs, metric
    /// keys, and JSON where ``description``'s sentence is more than a
    /// consumer wants. The case name, held stable across releases.
    public var code: String {
        switch self {
        case .notSwiftMangled: "notSwiftMangled"
        case .malformed: "malformed"
        }
    }
}
