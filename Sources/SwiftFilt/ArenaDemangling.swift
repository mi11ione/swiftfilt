// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// The string→string demangling path routed through the bump-arena
// `ArenaBuilder` backend: mangled bytes in, rendered name out, with no
// per-node `[SwiftSymbol]` allocation and no `SwiftSymbol` value tree ever
// materialized. The structured entry points (`SwiftDemangler.demangle(symbol:)`,
// `DemangledSymbol`, `--tree`/`--json`, `MangledNameScanner.matches`) keep the
// value backend, whose public `SwiftSymbol` is their contract.

/// One reusable arena demangle+render engine: the `ArenaBuilder`, the
/// `Demangler`, and the `NodePrinter` as a unit, each resettable in place, so
/// a batch (``DemangleSession``, the scanner's candidate stream) demangles
/// every symbol through one set of objects — zero per-symbol engine
/// allocation after warmup. The one-shot product `demangle(_:style:)` spins up
/// a fresh engine per call, which is exactly the pre-session allocation
/// budget. Reused-engine behavior is pinned byte-for-byte against the
/// fresh-engine path (and the `SwiftSymbol` value backend) by the
/// `swiftfilt-parity differential` session leg over the full corpus.
/// `package` so the CLI's streaming filter (one `scanRendered` call per
/// framed line) can hold ONE engine across its whole stream instead of
/// constructing arena+printer+demangler per line; the type and its members
/// stay non-public — implementation machinery, not product surface.
package final class ArenaDemangleEngine {
    let arena: ArenaBuilder
    /// The struct printer mutates in place through this class property; the
    /// property access spans one whole render (reset/printRoot/takeString are
    /// single formal accesses each).
    @exclusivity(unchecked) private var printer: NodePrinter<ArenaBuilder>

    package init() {
        let arena = ArenaBuilder()
        self.arena = arena
        printer = NodePrinter(options: PrinterOptions(style: .full), nb: arena)
    }

    /// The scan-buffer demangler: created once per ``beginBuffer(_:)`` over
    /// one immutable buffer, then re-windowed per candidate — `text` stays
    /// `let`-immutable (the byte-read-heavy parse's loop-invariance; an
    /// in-place *text*-resettable demangler measured −2.4% on the one-shot
    /// stream) while candidates cost no engine allocation and no byte copy.
    private var bufferDemangler: Demangler<ArenaBuilder>?

    /// The parse-stack slab shuttled into each per-call demangler (see
    /// `Demangler.init(text:nb:taking:)`): a session's or scan's calls
    /// share ONE set of stacks, so steady-state calls allocate none — and
    /// capacity earned on a deep symbol keeps serving later calls. Starts
    /// as the empty placeholder (the first call's take allocates the slab);
    /// exactly one of {this, an active demangler} holds the warm slab, so
    /// the deinit destroy below and the demangler's own destroy never
    /// double-free.
    private var storage = EngineStacks<ArenaBuilder.Node>()

    deinit {
        storage.destroy()
    }

    /// Demangle `bytes` as a global symbol on a rewound arena, returning the
    /// root handle (or `nil` when the name does not parse). The handle is
    /// valid until the next `demangle`. A fresh `Demangler` per call (each
    /// call is a new buffer) borrowing the engine's warm stacks; it dies
    /// with the parse — the arena's input binding, not the demangler, keeps
    /// the buffer alive for zero-copy rendering. The arena slabs, the
    /// printer's byte buffer, and the shuttled stacks are what session
    /// reuse keeps warm.
    func demangle(_ bytes: [UInt8]) -> ArenaBuilder.Node? {
        // Structural coherence: a whole-buffer demangle must never parse
        // under a stale window pin (its identifiers would index the wrong
        // buffer), whatever the call interleaving. Unpinning when no pin is
        // set is two stores.
        arena.unpinInput()
        arena.reset()
        var demangler = Demangler(text: bytes, nb: arena, taking: &storage)
        defer { demangler.giveBack(&storage) }
        return demangler.demangleSymbol()
    }

    /// Install `buffer` as the scan buffer: candidates then parse as windows
    /// of it through ``demangle(window:)`` — one demangler, one retained
    /// buffer, zero per-candidate copies (the arena's zero-copy identifier
    /// ranges point straight into the scan buffer). The buffer must outlive
    /// the scan and not be mutated during it — the scanner's input is
    /// immutable by construction.
    func beginBuffer(_ buffer: [UInt8]) {
        arena.reset()
        // Pin the buffer as the arena's verbatim-text binding for the whole
        // scan: candidates then skip the per-window bind (a retain/release
        // pair per candidate — measured as the dominant cross-thread
        // contention when parallel workers scanned a shared region, and a
        // small win on every single-threaded scan too).
        arena.pinInput(buffer)
        bufferDemangler = Demangler(text: buffer, nb: arena, taking: &storage)
    }

    /// Demangle the scan buffer's `window` as a global symbol on a rewound
    /// arena — the per-candidate parse. Only valid between ``beginBuffer(_:)``
    /// and ``endBuffer()``. The demangler is a noncopyable struct, so it is
    /// rewound and driven *in place* through the optional chain — never
    /// bound out (which would move it).
    func demangle(window: Range<Int>) -> ArenaBuilder.Node? {
        guard bufferDemangler != nil else { return nil }
        arena.reset()
        bufferDemangler?.reset(range: window)
        return bufferDemangler?.demangleSymbol() ?? nil
    }

    /// Release the scan buffer (demangler and arena binding), reclaiming
    /// the warm parse stacks for the next scan or call.
    func endBuffer() {
        bufferDemangler?.giveBack(&storage)
        bufferDemangler = nil // consumes the demangler; its deinit destroys the placeholder
        arena.unpinInput()
        arena.reset()
    }

    /// Render `root` in `style` through the reused printer. Callable more
    /// than once per demangle (the scanner validates in `.full`, then
    /// re-renders the requested style from the same tree).
    func render(_ root: ArenaBuilder.Node, style: SwiftDemanglerPrinter.Style) -> String {
        printer.reset(options: PrinterOptions(style: style))
        printer.printRoot(root)
        return printer.takeString()
    }

    /// Demangle + render in one step; `nil` when the name does not parse or
    /// the (degenerate) tree renders to nothing — the product contract of
    /// `demangle(_:style:)`.
    func demangleAndRender(_ bytes: [UInt8], style: SwiftDemanglerPrinter.Style) -> String? {
        guard let root = demangle(bytes) else { return nil }
        let rendered = render(root, style: style)
        return rendered.isEmpty ? nil : rendered
    }
}

/// String-only demangle+render over ``ArenaBuilder``. The one-shot product
/// entry (`demangle(_:style:)`) drives the arena through here; the batch
/// paths hold an ``ArenaDemangleEngine``.
enum ArenaDemangling {
    /// Demangle `bytes` as a global symbol in `arena` (which the caller has
    /// reset) and render in `style`; `nil` when the name does not parse or the
    /// (degenerate) tree renders to nothing. `demangleSymbol` monomorphizes at
    /// `ArenaBuilder` (see the `@_specialize` on the hot chain), and the printer
    /// reads the arena through O(1) index accessors, so the whole path is free
    /// of per-node allocation.
    @inline(__always)
    static func demangleAndRender(_ bytes: [UInt8], style: SwiftDemanglerPrinter.Style, arena: ArenaBuilder) -> String? {
        var demangler = Demangler(text: bytes, nb: arena)
        guard let root = demangler.demangleSymbol() else { return nil }
        var printer = NodePrinter<ArenaBuilder>(options: PrinterOptions(style: style), nb: arena)
        printer.printRoot(root)
        let rendered = printer.takeString()
        return rendered.isEmpty ? nil : rendered
    }

    /// One-shot demangle+render on a fresh arena (the single-symbol product
    /// call). Constructs the parts directly — no engine wrapper, no reset
    /// pass — because a fresh call needs neither, and the indirection
    /// measured ~5% on the stream benchmark. The fresh builder's reserved
    /// slabs and buffers are its entire allocation budget — no
    /// `[SwiftSymbol]` per node, no ARC teardown. Byte-identical to the
    /// session path (the differential's session leg pins the two together).
    static func render(symbolBytes bytes: [UInt8], style: SwiftDemanglerPrinter.Style) -> String? {
        demangleAndRender(bytes, style: style, arena: ArenaBuilder())
    }
}
