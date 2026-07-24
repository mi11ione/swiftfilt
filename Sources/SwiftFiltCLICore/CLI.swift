// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt

/// The `swiftfilt` tool: argv and raw input bytes in, raw output bytes
/// out, exit code back.
///
/// Exit codes: ``exitSuccess`` (0) for every completed run — echoing a
/// non-symbol back unchanged is success (c++filt semantics); ``exitUsage``
/// (2) for a malformed command line (the grep/shell convention that 2 means
/// misuse); ``exitInternalError`` (1) for a runtime failure, which today
/// exactly one thing earns: the census refusing to print a report whose
/// accounting does not add up (a swiftfilt bug, never bad input). Data goes
/// to `writeOutput` (stdout) only; errors to `writeError` (stderr) only.
public enum CLI {
    /// The tool's version, printed by `--version` — the package's single
    /// source of truth (the parity instrument reads it too); a release tag
    /// must equal this string exactly.
    public static let version = "1.0.0"

    /// Exit code for success (including echo-through of non-symbols).
    public static let exitSuccess: Int32 = 0
    /// Exit code for an internal failure: the census's accounting
    /// self-check found its own books unbalanced — a swiftfilt bug,
    /// reported on stderr, never printed as a plausible-looking report.
    public static let exitInternalError: Int32 = 1
    /// Exit code for a usage error (unknown flag, conflicting flags,
    /// missing or invalid flag value).
    public static let exitUsage: Int32 = 2

    /// Run one invocation.
    ///
    /// - Parameters:
    ///   - arguments: argv after the executable name.
    ///   - input: The injected byte source: each call returns the next
    ///     chunk of raw input (any non-empty size), or `nil` at end of
    ///     input. Only filter mode (no symbol arguments) ever calls it.
    ///   - inputAvailable: Whether another `input()` call would return
    ///     immediately (more bytes are already buffered, or end of input
    ///     is already reached) — the saturation probe the parallel filter
    ///     coalesces reads on. `nil` (the default) disables coalescing;
    ///     the probe must never block.
    ///   - makeWorkerPool: Builds the worker pool for parallel filter
    ///     rewriting, given the `--jobs` request (`0` means choose
    ///     automatically). `nil` (the default) or a returned `nil` keeps
    ///     every path sequential. Called at most once, and only when a
    ///     rewrite-mode filter run could use it.
    ///   - writeOutput: The stdout sink. Raw bytes, so filter output
    ///     round-trips arbitrary (non-UTF-8 included) input byte-for-byte.
    ///     In filter mode everything one input chunk completes is written in
    ///     one call *before* the next chunk is read — never the accumulated
    ///     stream — so an unbuffered wiring layer gives live `tail -f`
    ///     pipelines with no syscall per line. (Coalesced reads — see
    ///     `inputAvailable` — hold the same.) Always called from the thread
    ///     `run` was called on.
    ///   - writeError: The stderr sink (usage errors; always valid text).
    ///   - standardOutputIsTTY: Whether stdout is a terminal, for
    ///     `--color auto`.
    /// - Returns: The process exit code.
    public static func run(
        arguments: [String],
        input: () -> [UInt8]?,
        inputAvailable: (() -> Bool)? = nil,
        makeWorkerPool: ((Int) -> FilterWorkerPool?)? = nil,
        writeOutput: ([UInt8]) -> Void,
        writeError: (String) -> Void,
        standardOutputIsTTY: Bool,
        fileExists: (String) -> Bool = { _ in false },
    ) -> Int32 {
        switch ParsedCommandLine.parse(arguments) {
        case .help:
            writeOutput(Array(helpText.utf8))
            return exitSuccess
        case .version:
            writeOutput(Array("swiftfilt \(version)\n".utf8))
            return exitSuccess
        case let .usageError(message):
            writeError(message + "\n")
            writeError("run 'swiftfilt --help' for usage\n")
            return exitUsage
        case let .census(invocation):
            return CensusCommand.run(
                invocation, input: input, makeWorkerPool: makeWorkerPool,
                writeOutput: writeOutput, writeError: writeError,
                standardOutputIsTTY: standardOutputIsTTY,
            )
        case let .explain(invocation):
            return ExplainCommand.run(
                invocation, input: input, writeOutput: writeOutput, standardOutputIsTTY: standardOutputIsTTY,
            )
        case let .run(invocation):
            run(
                invocation, input: input, inputAvailable: inputAvailable,
                makeWorkerPool: makeWorkerPool, writeOutput: writeOutput,
                writeError: writeError, standardOutputIsTTY: standardOutputIsTTY,
                fileExists: fileExists,
            )
            return exitSuccess
        }
    }

    /// Dispatch a parsed invocation: symbol-args mode when arguments were
    /// given, the stdin filter otherwise.
    static func run(
        _ invocation: Invocation,
        input: () -> [UInt8]?,
        inputAvailable: (() -> Bool)? = nil,
        makeWorkerPool: ((Int) -> FilterWorkerPool?)? = nil,
        writeOutput: ([UInt8]) -> Void,
        writeError: (String) -> Void,
        standardOutputIsTTY: Bool,
        fileExists: (String) -> Bool,
    ) {
        if invocation.demangleAsType {
            runTypes(invocation, input: input, writeOutput: writeOutput)
        } else if invocation.symbols.isEmpty {
            runFilter(
                invocation, input: input, inputAvailable: inputAvailable,
                makeWorkerPool: makeWorkerPool, writeOutput: writeOutput,
                standardOutputIsTTY: standardOutputIsTTY,
            )
        } else {
            runSymbols(invocation, writeOutput: writeOutput, writeError: writeError, fileExists: fileExists)
        }
    }

    /// `--type` mode: each whole input is a bare type mangling (no `$s`
    /// prefix), rendered in the invocation's style, or echoed unchanged when
    /// it is not exactly one valid type (c++filt semantics). Inputs are the
    /// symbol arguments, or — when none are given — standard-input lines, one
    /// type per line. Never scans for embedded names and never colorizes: the
    /// whole line is the type.
    static func runTypes(
        _ invocation: Invocation,
        input: () -> [UInt8]?,
        writeOutput: ([UInt8]) -> Void,
    ) {
        let inputs = invocation.symbols.isEmpty ? StreamLines.read(input) : invocation.symbols
        for argument in inputs {
            let line = SymbolText.typeArgumentLine(argument, style: invocation.style)
            writeOutput(Array((line + "\n").utf8))
        }
    }

    /// Symbol-args mode: each argument on its own line (text), its tree
    /// block, or its NDJSON record. Arguments are always symbols, never
    /// file paths; stdin is never read (an argument that names an existing
    /// file earns a stderr hint — stdout stays c++filt-pure). Bare
    /// sigil-less manglings are retried with `$` prepended, mirroring
    /// `swift-demangle`. Color never applies here — the whole line is the
    /// demangling, so there is nothing to set off.
    static func runSymbols(
        _ invocation: Invocation,
        writeOutput: ([UInt8]) -> Void,
        writeError: (String) -> Void,
        fileExists: (String) -> Bool,
    ) {
        for argument in invocation.symbols {
            switch invocation.mode {
            case let .text(classify):
                let line = SymbolText.argumentLine(argument, style: invocation.style, classify: classify)
                writeOutput(Array((line + "\n").utf8))
                if SymbolText.acceptedArgument(argument) == nil, fileExists(argument) {
                    writeError("swiftfilt: note: '\(argument)' names a file, but arguments are always symbols — to filter its contents: swiftfilt < \(argument)\n")
                }
            case .tree:
                // c++filt echo semantics: a non-demangling argument echoes
                // unchanged, not swift-demangle's `<<NULL>>` placeholder.
                if let symbol = SymbolText.acceptedArgument(argument) {
                    writeOutput(Array(SymbolText.treeBlock(mangled: symbol.mangledName, symbol: symbol.symbol).utf8))
                } else {
                    writeOutput(Array((argument + "\n").utf8))
                }
            case let .json(slim):
                // One record per argument that demangles; a non-symbol emits
                // nothing by default (the stream is exactly the demangled
                // symbols), or a `kind:"decline"` record under
                // --include-declines so a batch reports which failed and why.
                guard let symbol = SymbolText.acceptedArgument(argument) else {
                    if invocation.includeDeclines {
                        let record = JSONText.declineLine(mangled: argument, slim: slim)
                        writeOutput(Array((record + "\n").utf8))
                    }
                    continue
                }
                let record = JSONText.symbolLine(symbol, style: invocation.style, slim: slim)
                writeOutput(Array((record + "\n").utf8))
            }
        }
    }

    /// Filter mode: stream stdin through the line filter.
    static func runFilter(
        _ invocation: Invocation,
        input: () -> [UInt8]?,
        inputAvailable: (() -> Bool)?,
        makeWorkerPool: ((Int) -> FilterWorkerPool?)?,
        writeOutput: ([UInt8]) -> Void,
        standardOutputIsTTY: Bool,
    ) {
        let mode: FilterStream.Mode
        var colorable = false
        switch invocation.mode {
        case let .text(classify):
            mode = .rewrite(classify: classify)
            colorable = true
        case .tree:
            mode = .tree
        case let .json(slim):
            // JSON is never colored, whatever --color says: escapes
            // inside machine output corrupt it.
            mode = .json(slim: slim)
        }
        let palette = Palette(
            enabled: colorable && invocation.color.resolved(standardOutputIsTTY: standardOutputIsTTY),
        )
        // Parallel rewriting engages only for the rewrite modes (tree/JSON
        // stay sequential for their line-number provenance — the parser
        // rejects an explicit --jobs there), only when a pool was provided,
        // and never for `--jobs 1`.
        var parallel: ParallelRewriter?
        if case .rewrite = mode, invocation.jobs != 1, let makeWorkerPool,
           let pool = makeWorkerPool(invocation.jobs ?? 0), pool.workerCount >= 2
        {
            parallel = ParallelRewriter(pool: pool)
        }
        var stream = FilterStream(mode: mode, style: invocation.style, palette: palette, parallel: parallel)
        if let parallel, let inputAvailable {
            // Saturated input coalesces already-available reads into one
            // region-sized round so worker spans stay big; the probe never
            // blocks, so a trickle (`tail -f`) falls through to one consume
            // per read — the exact sequential liveness. EOF mid-coalesce
            // ends the round; the outer loop then sees end of input. The
            // round buffer's capacity is reused across rounds (per-round
            // megabyte buffers were a peak-RSS driver).
            let target = parallel.roundTargetBytes
            var round: [UInt8] = []
            while let chunk = input() {
                round.removeAll(keepingCapacity: true)
                round.append(contentsOf: chunk)
                while round.count < target, inputAvailable(), let more = input() {
                    round.append(contentsOf: more)
                }
                stream.consume(round, emit: writeOutput)
            }
        } else {
            while let chunk = input() {
                stream.consume(chunk, emit: writeOutput)
            }
        }
        stream.finish(emit: writeOutput)
    }

    /// The `swiftfilt --help` text.
    public static let helpText = """
    swiftfilt demangles Swift symbols — a c++filt-style stream filter and
    a per-symbol demangler over the SwiftFilt engine.

    usage:
      swiftfilt [options]                filter standard input to standard output
      swiftfilt [options] <symbol> ...   demangle each symbol argument
      swiftfilt census [options]         symbol-population analytics over stdin
      swiftfilt explain <symbol> ...     diagnose a symbol: demangle it, or say why not

    Filter mode (no symbol arguments) rewrites every embedded Swift mangled
    name in place and passes everything else through byte-for-byte, invalid
    UTF-8 included — crash logs, nm and linker output, ANSI-colored build
    logs. Lines stream one at a time, each flushed as it completes, so live
    `tail -f` pipelines render immediately.

    Symbol-args mode prints one line per argument: its demangling, or the
    argument echoed unchanged when it does not demangle (c++filt
    semantics). A bare sigil-less mangling (`s4main…` with its `$`
    stripped by a shell or log) is retried with the `$` restored, as
    swift-demangle does. Arguments are always symbols, never file paths —
    standard input is the only stream input (an argument that names an
    existing file earns a stderr hint). `--` ends option parsing for
    symbols that start with `-`.

    Census mode (`swiftfilt census`, first argument exactly) aggregates the
    Swift symbol population read from standard input: totals, kinds,
    modules, which generic origins specialized how many times and at what
    cost, how many copies of one logical function exist, and the
    compiler-generated machinery share. Size-weighted when the input
    carries sizes (an Xcode LinkMap, a sized nm dump), count-weighted
    otherwise — the report always says which. Skipped and dead-stripped
    rows are counted and reported, never silently dropped.

    Explain mode (`swiftfilt explain`, first argument exactly) tells the
    full story of each symbol argument — or, with no arguments, of each
    symbol read from standard input, one per line (the `nm | grep |
    swiftfilt explain` shape). When it demangles: the mangling era
    ($s / $e / _T0 / _T / @__swiftmacro_), the curated kind, module and
    path, every validated rendering, and the crash-grouping identity key.
    When it does not: whether it is even Swift, which era it claims, the
    byte the parse stopped at and why (a truncated identifier, a stray
    byte, an unfinished production), any complete Swift name found embedded
    inside it, and — for a non-Swift name — which other demangler to try
    (`_Z` → c++filt, `_R` → rustfilt). `--json` emits one explain object
    per argument (schemaVersion 1), so a declined symbol becomes a
    scriptable record instead of silence.

    style options (mutually exclusive; default is swift-demangle's full form):
      --simplified                 the crash-reporter rendering: no module
                                   qualification, no argument/return types
                                   (swift-demangle -simplified)
      --qualified                  fully qualified with no type sugar —
                                   Swift.Optional<Swift.Int>, never Int?
                                   (swift-demangle -no-sugar)
      --unqualified                sugared types, no module/context
                                   qualification

    output options (mutually exclusive):
      --tree                       print each symbol's node tree instead of
                                   rewriting (swift-demangle -tree-only form);
                                   in filter mode, one tree per located name
      --classify                   prefix each demangling with its
                                   swift-demangle -classify markers
                                   ({N} not Swift, {T:target} thunk, {C}
                                   non-Swift calling convention)
      --json                       NDJSON: one object per demangled symbol,
                                   schemaVersion 1 (mangled, demangled, style,
                                   module, path, kind, isStatic, isThunk,
                                   isSpecialized, genericOrigin, identityKey,
                                   and line/byteOffset in filter mode —
                                   byteOffset counts from its line's start).
                                   An argument that does not demangle emits
                                   no record by default; the stream is
                                   exactly the demangled symbols
      --slim                       with --json, drop the constant and
                                   empty/false fields (every kept field is
                                   byte-identical to the full record's)
      --include-declines           with --json symbol arguments, also emit a
                                   kind:"decline" record for an argument that
                                   does not demangle (the same era/status/
                                   reason/stop-position diagnosis explain
                                   gives), so a batch reports which failed and
                                   why. Symbol-args mode only — the stdin
                                   filter passes non-manglings through by
                                   design

    type mode:
      --type                       read each argument (or, with no arguments,
                                   each standard-input line) as a bare type
                                   mangling — the reflection / swift-demangle
                                   -type form with no $s prefix — and demangle
                                   it as a type (SaySiG -> [Swift.Int]).
                                   Composes with the style flags above; a
                                   string that is not exactly one valid type
                                   echoes back unchanged (never a fabricated
                                   name)

    census options:
      --format <bare|nm|linkmap>   input format (default: auto-detected
                                   from content; the report shows the
                                   detection reasoning)
      --top <N>                    rows per ranked table in the human
                                   report (default 10; --json always
                                   carries every row)
      --json                       the census as NDJSON: one summary object
                                   (kind "census": format, weight, detection,
                                   lines, rows/rowBytes, swift, nonSwift,
                                   malformed, contentAtoms, embeddedMangling,
                                   linkerPlumbing, implausibleSizes,
                                   machinery, human, specialized, and the
                                   per-format extras), then one object per
                                   table row (kind "censusRow": table, name,
                                   count, bytes), under the same
                                   schemaVersion 1 contract
      --slim                       with --json, drop the constant fields
      --jobs <N>                   worker threads for the per-row demangle
                                   over a large bare/nm listing (default:
                                   one per CPU; 1 disables). The report and
                                   --json are byte-identical at every
                                   setting; linkmap parses single-threaded

    other options:
      --color <auto|always|never>  colorize rewritten names in filter mode
                                   and census report headings (default
                                   auto: only on a terminal; JSON and tree
                                   output are never colored)
      --jobs <N>                   worker threads for filter-mode rewriting
                                   when input saturates (default: one per
                                   CPU; 1 disables). Output bytes and order
                                   are identical at every setting; live
                                   trickles (tail -f) always stream
                                   line-at-a-time regardless
      --version                    print the version
      --help, -h                   print this help

    examples:
      # demangle a crash log
      swiftfilt < crash.log
      # follow a build log live, frame names only
      tail -f build.log | swiftfilt --simplified
      # demangle an app's symbol table
      nm MyApp.app/Contents/MacOS/MyApp | swiftfilt
      # one symbol, straight from the shell
      swiftfilt '$s4main3fooyyF'
      # diagnose a symbol that will not demangle (truncated, corrupt, or not Swift)
      swiftfilt explain '$s4main9foo'
      # crash-group frames: one JSON record per symbol, keyed for grouping
      swiftfilt --json --slim < crash.log | jq -r .identityKey | sort | uniq -c
      # census what ships in a binary, size-weighted (link with
      # -Xlinker -map -Xlinker LinkMap.txt to get the map)
      swiftfilt census < LinkMap.txt
      # census a built app's symbol population, count-weighted
      nm MyApp.app/Contents/MacOS/MyApp | swiftfilt census
      # CI gate: fail the build when thunk bytes exceed a 256 KiB budget
      swiftfilt census --json < LinkMap.txt | jq -es 'map(select(.table=="kinds" and (.name|startswith("thunk."))).bytes) | add // 0 | . < 262144'
      # demangle a bare runtime type string (reflection / swift-demangle -type)
      swiftfilt --type 'SaySiG'
      # explain a whole list of symbols, one per line
      swiftfilt explain < symbols.txt

    exit codes:
      0  success (echoed non-symbols included — c++filt semantics)
      1  internal error (census accounting self-check failed: a swiftfilt
         bug reported on stderr, never a report with unbalanced numbers)
      2  usage error (unknown flag, conflicting flags, bad flag value)

    """
}
