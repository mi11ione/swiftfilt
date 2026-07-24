// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

/// A reusable demangling session: ``demangle(_:style:)``'s exact behavior,
/// amortizing the engine's working storage across calls.
///
/// The one-shot ``demangle(_:style:)`` builds a fresh engine — node arena,
/// parser, printer — for every call; that construction is the dominant
/// per-call allocation cost once the demangle itself is arena-backed. A
/// session builds the engine once and rewinds it in place between calls, so
/// a batch caller (a crash reporter demangling thousands of frames, a
/// symbol-table pass, a log pipeline) pays the engine's storage once and
/// each call allocates only its input copy and output string:
///
/// ```swift
/// let session = DemangleSession()
/// for frame in stackFrames {
///     if let name = session.demangle(frame.symbol) {
///         frame.display = name
///     }
/// }
/// ```
///
/// Output is byte-for-byte identical to ``demangle(_:style:)`` for every
/// input and style — the session leg of the parity differential holds the
/// reused engine equal to the fresh engine across the full multi-million-
/// symbol corpus. `nil` exactly when ``demangle(_:style:)`` returns `nil`.
///
/// A session is deliberately **not** `Sendable`: it is one engine's mutable
/// state. Use one session per thread or task (they are cheap — three small
/// objects and their buffers); sharing one across concurrent callers is a
/// data race, exactly as sharing any other mutable buffer would be.
public final class DemangleSession {
    private let engine = ArenaDemangleEngine()

    /// Creates a session holding one reusable demangling engine.
    public init() {}

    /// The demangled form of a Swift mangled name, or `nil` when the name
    /// does not demangle — ``demangle(_:style:)``, amortized.
    ///
    /// Accepts every mangling era the one-shot call accepts (`$s`/`$S`/`$e`,
    /// `_T0`, legacy `_T…`, `@__swiftmacro_`, each with or without the
    /// Mach-O leading underscore, including the doubled `__T…` form) and
    /// renders identically, style for style.
    ///
    /// - Parameters:
    ///   - mangledName: The mangled symbol name.
    ///   - style: The rendering preset; ``DemangleStyle/full`` matches plain
    ///     `swift-demangle` output.
    /// - Returns: The demangled name, or `nil` when `mangledName` does not
    ///   demangle (never an empty string).
    public func demangle(_ mangledName: String, style: DemangleStyle = .full) -> String? {
        let adapted = mangledName.hasPrefix("__T") ? String(mangledName.dropFirst()) : mangledName
        return engine.demangleAndRender(Array(adapted.utf8), style: style.printerStyle)
    }
}
