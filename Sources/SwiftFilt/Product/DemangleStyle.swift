// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

/// A demangled-name rendering preset.
///
/// These are the four corpus-validated presets — every one is held to
/// byte-parity with a `swift-demangle` output mode over the library's
/// golden corpus of real-world symbols. There is deliberately no way to
/// compose custom printer-option combinations: an unvalidated combination
/// would carry no parity guarantee, so the library does not offer one.
///
/// `DemangleStyle` is the product-surface twin of the node-tier
/// ``SwiftDemanglerPrinter/Style``; the cases correspond one to one.
public enum DemangleStyle: Sendable, Hashable, CaseIterable {
    /// The default: fully qualified names with sugared types — exactly what
    /// plain `swift-demangle` (and its `-compact` flag) prints, and the form
    /// most Apple tooling shows.
    ///
    /// Modules and contexts are spelled out (`Swift.Array`), type sugar is
    /// synthesized (`[Int]`, `Int?`), and full signatures are shown:
    /// `main.fetch(url: Foundation.URL) async throws -> [Swift.Int]`.
    case full

    /// The "simplified UI" style — `swift-demangle -simplified`, the
    /// rendering crash-reporting SDKs and symbolication UIs use for frame
    /// names.
    ///
    /// Drops module qualification, argument and return types, generic
    /// specialization payloads, protocol conformance clauses, and private
    /// discriminators; thunks and value witnesses shorten to a bare marker:
    /// `fetch(url:)`, `closure #1 in viewDidLoad()`, `thunk for @escaping
    /// @callee_guaranteed () -> ()`.
    case simplified

    /// Fully qualified with no type sugar — `swift-demangle -no-sugar`.
    ///
    /// Every type is spelled canonically (`Swift.Optional<Swift.Int>`,
    /// `Swift.Array<Swift.String>`, never `Int?` or `[String]`), making this
    /// the most canonical, comparison-stable rendering. Identity keys
    /// (``DemangledSymbol/identityKey``) print in this style.
    case qualified

    /// Sugared names with no module or context qualification — the
    /// leaf-name rendering (`DemangleOptions` with `QualifyEntities` off).
    ///
    /// `fetch(url: URL) async throws -> [Int]` rather than the
    /// `main.`-qualified form. Useful for compact displays where context
    /// is already known.
    case unqualified

    /// The engine printer preset this style selects.
    var printerStyle: SwiftDemanglerPrinter.Style {
        switch self {
        case .full: .full
        case .simplified: .simplified
        case .qualified: .qualified
        case .unqualified: .unqualified
        }
    }
}
