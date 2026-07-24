// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt

/// `--color` policy: when filter-mode replacements may carry ANSI escapes.
@frozen
public enum ColorMode: String, Sendable, Hashable, CaseIterable {
    /// Color iff standard output is a terminal — never when piped.
    case auto
    /// Color unconditionally.
    case always
    /// Plain text unconditionally.
    case never

    /// Resolve the policy against the actual output destination.
    @inlinable
    public func resolved(standardOutputIsTTY: Bool) -> Bool {
        switch self {
        case .auto: standardOutputIsTTY
        case .always: true
        case .never: false
        }
    }
}

/// What one invocation prints. The modes are mutually exclusive by
/// construction — the parser rejects flag combinations that would ask for
/// two at once, so downstream code never arbitrates.
@frozen
public enum OutputMode: Sendable, Hashable {
    /// The default: demangled text. In filter mode every validated mangled
    /// name is rewritten in place; in symbol-args mode each argument
    /// demangles onto its own line (echoed unchanged when it does not
    /// demangle — c++filt semantics). With `classify`, each demangling is
    /// prefixed by the `swift-demangle -classify` marker string
    /// (`{N}` / `{T:target}` / `{C}`) when one applies.
    case text(classify: Bool)
    /// `--tree`: the node tree of each symbol (args mode) or each located
    /// mangling (filter mode; nothing is rewritten), in
    /// `swift-demangle -tree-only` form.
    case tree
    /// `--json`: NDJSON, one object per demangled symbol
    /// (see ``JSONText``). `slim` selects the compact projection.
    case json(slim: Bool)
}

/// One parsed `swiftfilt` invocation.
@frozen
public struct Invocation: Sendable, Hashable {
    /// The symbol arguments; empty selects filter mode (read stdin).
    public var symbols: [String]
    /// The rendering preset for demangled names (default ``DemangleStyle/full``).
    public var style: DemangleStyle
    /// What to print.
    public var mode: OutputMode
    /// `--color` policy (filter-mode text replacements only).
    public var color: ColorMode
    /// `--jobs` worker-thread request for the rewriting filter under
    /// saturated input: `nil` chooses automatically, `1` forces the
    /// sequential path, higher values cap the pool. Output bytes are
    /// identical at every setting.
    public var jobs: Int?
    /// `--include-declines` (with `--json`, symbol-args mode): also emit a
    /// `kind:"decline"` record for a symbol argument that does not
    /// demangle, carrying the same diagnosis `explain` gives, so a batch
    /// of `--json` symbols reports which ones failed and why instead of
    /// silently dropping them. The default `--json` stream stays exactly
    /// the demangled symbols.
    public var includeDeclines: Bool
    /// `--type`: interpret each whole input (symbol argument, or standard-input
    /// line when no arguments are given) as a bare *type* mangling — the
    /// reflection / `swift-demangle -type` form with no `$s` global prefix —
    /// and demangle it as a type. Composes with the four render styles; the
    /// output modes (`--tree`/`--json`/`--classify`) and the rewriting filter
    /// do not apply (a bare type carries no node-classify markers, no entity
    /// JSON schema, and does not appear embedded in a log stream). A string
    /// that is not exactly one valid type echoes back unchanged (c++filt
    /// semantics), never the reference's `<<invalid type>>` fabrication.
    public var demangleAsType: Bool

    public init(
        symbols: [String] = [],
        style: DemangleStyle = .full,
        mode: OutputMode = .text(classify: false),
        color: ColorMode = .auto,
        jobs: Int? = nil,
        includeDeclines: Bool = false,
        demangleAsType: Bool = false,
    ) {
        self.symbols = symbols
        self.style = style
        self.mode = mode
        self.color = color
        self.jobs = jobs
        self.includeDeclines = includeDeclines
        self.demangleAsType = demangleAsType
    }
}

/// One parsed `swiftfilt explain` invocation: the symbols to explain and
/// the output shape. Explain reads its arguments as symbols only (never
/// standard input, never file paths), one structured story per argument.
@frozen
public struct ExplainInvocation: Sendable, Hashable {
    /// The symbols to explain, in order.
    public var symbols: [String]
    /// `--json`: NDJSON, one `explain` object per argument (see ``JSONText``).
    public var json: Bool
    /// `--slim`: with `--json`, drop the constant fields.
    public var slim: Bool
    /// `--color` policy for the human report's headings.
    public var color: ColorMode

    public init(symbols: [String] = [], json: Bool = false, slim: Bool = false, color: ColorMode = .auto) {
        self.symbols = symbols
        self.json = json
        self.slim = slim
        self.color = color
    }
}

/// Result of parsing argv (everything after the executable name).
@frozen
public enum ParsedCommandLine: Sendable, Hashable {
    /// A well-formed filter / symbol-args invocation.
    case run(Invocation)
    /// A well-formed `census` invocation.
    case census(CensusInvocation)
    /// A well-formed `explain` invocation.
    case explain(ExplainInvocation)
    /// `--help` / `-h`.
    case help
    /// `--version`.
    case version
    /// A usage error with its message (exit code ``CLI/exitUsage``).
    case usageError(String)
}

public extension ParsedCommandLine {
    /// Parse argv. The grammar is `swiftfilt [options] [symbol ...]`, or
    /// `swiftfilt census [options]` when the first argument is the verb:
    /// flags and symbol arguments mix in any order, `--` ends option
    /// parsing (everything after it is a symbol, so a symbol beginning
    /// with `-` can be passed — including the literal word `census`),
    /// and the globals `--version` and `--help`/`-h` win wherever they
    /// appear. Conflicting flags are usage errors, never silent
    /// precedence: two different style flags, `--tree` with
    /// `--json`/`--classify`/a style flag, `--classify` with `--json`,
    /// `--slim` without `--json`, and census-only flags outside the verb
    /// are each rejected with a message that names the conflict.
    static func parse(_ arguments: [String]) -> ParsedCommandLine {
        // The globals win regardless of position (only up to a `--`:
        // after the end-of-options marker they are symbol text).
        var optionRegion = ArraySlice(arguments)
        if let marker = arguments.firstIndex(of: "--") {
            optionRegion = arguments[..<marker]
        }
        if optionRegion.contains("--version") {
            return .version
        }
        if optionRegion.contains("--help") || optionRegion.contains("-h") {
            return .help
        }

        // The census verb: first argument exactly (later positionals stay
        // symbols, and `-- census` forces the word to be a symbol).
        if arguments.first == "census" {
            return parseCensus(arguments.dropFirst())
        }

        // The explain verb: first argument exactly (the same rule as
        // census; `-- explain` forces the word to be a symbol).
        if arguments.first == "explain" {
            return parseExplain(arguments.dropFirst())
        }

        var symbols: [String] = []
        var styles: [(style: DemangleStyle, flag: String)] = []
        var tree = false
        var classify = false
        var json = false
        var slim = false
        var includeDeclines = false
        var demangleAsType = false
        var color: ColorMode = .auto
        var jobs: Int?
        var optionsEnded = false

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if optionsEnded {
                symbols.append(argument)
                continue
            }
            switch argument {
            case "--":
                optionsEnded = true
            case "--simplified":
                appendStyle(.simplified, flag: "--simplified", to: &styles)
            case "--qualified":
                appendStyle(.qualified, flag: "--qualified", to: &styles)
            case "--unqualified":
                appendStyle(.unqualified, flag: "--unqualified", to: &styles)
            case "--tree":
                tree = true
            case "--classify":
                classify = true
            case "--json":
                json = true
            case "--slim":
                slim = true
            case "--include-declines":
                includeDeclines = true
            case "--type":
                demangleAsType = true
            case "--color":
                guard index < arguments.count else {
                    return .usageError("swiftfilt: error: --color needs a value (auto, always, or never)")
                }
                guard let parsed = ColorMode(rawValue: arguments[index]) else {
                    return .usageError("swiftfilt: error: unknown color mode '\(arguments[index])' (expected auto, always, or never)")
                }
                color = parsed
                index += 1
            case "--jobs":
                guard index < arguments.count else {
                    return .usageError("swiftfilt: error: --jobs needs a value (a positive thread count; 1 disables parallelism)")
                }
                guard let parsed = Int(arguments[index]), parsed >= 1 else {
                    return .usageError("swiftfilt: error: --jobs expects a positive thread count, not '\(arguments[index])'")
                }
                jobs = parsed
                index += 1
            case "--format", "--top":
                return .usageError("swiftfilt: error: \(argument) applies to the census verb (swiftfilt census \(argument) …)")
            default:
                if argument.hasPrefix("-") {
                    return .usageError("swiftfilt: error: unknown option '\(argument)' (use -- before symbols that start with -)")
                }
                symbols.append(argument)
            }
        }

        // Style flags are mutually exclusive: each names one complete
        // corpus-validated preset, so combining two is a contradiction,
        // not a composition.
        if styles.count > 1 {
            let names = styles.map(\.flag).joined(separator: " and ")
            return .usageError("swiftfilt: error: \(names) are mutually exclusive (each selects one complete rendering)")
        }
        let style = styles.first?.style ?? .full

        // Mode conflicts. Every rejected pair is one where a flag would
        // otherwise be silently ignored — the errors keep the contract
        // honest instead of quietly dropping a request.
        if tree, json {
            return .usageError("swiftfilt: error: --tree and --json are two output formats; use one")
        }
        if tree, classify {
            return .usageError("swiftfilt: error: --tree prints node trees, which carry no --classify markers; use one")
        }
        if tree, let styled = styles.first {
            return .usageError("swiftfilt: error: \(styled.flag) does not apply to --tree (node trees have no rendering style)")
        }
        if classify, json {
            return .usageError("swiftfilt: error: --classify markers are not part of the --json schema; use one")
        }
        if slim, !json {
            return .usageError("swiftfilt: error: --slim shapes --json output; add --json (or drop --slim)")
        }
        if jobs != nil, tree || json {
            let flag = tree ? "--tree" : "--json"
            return .usageError("swiftfilt: error: --jobs applies to the rewriting filter; \(flag) streams sequentially for its line-number provenance")
        }
        if includeDeclines, !json {
            return .usageError("swiftfilt: error: --include-declines adds decline records to --json output; add --json (or drop --include-declines)")
        }
        // Declines are well-defined only for symbol *arguments* (each is a
        // symbol the caller named). The stdin filter passes non-manglings
        // through by design — its scanner cannot tell a truncated symbol
        // from coincidental prose — so decline records there would report
        // text as symbols; `explain` is the sanctioned per-symbol diagnosis.
        if includeDeclines, symbols.isEmpty {
            return .usageError("swiftfilt: error: --include-declines surfaces declined symbol arguments; the stdin filter has none to surface — pass the symbols as arguments, or diagnose one with 'swiftfilt explain'")
        }
        // `--type` demangles a bare type and composes with the render styles
        // only. The output modes describe entity symbols, not a type — reject
        // rather than silently ignore, the same contract the other pairs keep.
        if demangleAsType, tree {
            return .usageError("swiftfilt: error: --type prints demangled type text in a render style; --tree is not combinable with it")
        }
        if demangleAsType, json {
            return .usageError("swiftfilt: error: --type demangles a bare type; the --json schema (module, kind, path, identityKey) describes entity symbols, not a type — use one")
        }
        if demangleAsType, classify {
            return .usageError("swiftfilt: error: --type demangles a bare type, which carries no --classify markers; use one")
        }
        if demangleAsType, jobs != nil {
            return .usageError("swiftfilt: error: --jobs applies to the rewriting filter; --type demangles its arguments (and stdin lines) sequentially")
        }

        let mode: OutputMode = tree ? .tree : json ? .json(slim: slim) : .text(classify: classify)
        return .run(Invocation(
            symbols: symbols, style: style, mode: mode, color: color, jobs: jobs,
            includeDeclines: includeDeclines, demangleAsType: demangleAsType,
        ))
    }

    /// Record a style flag, once — repeating the *same* flag is
    /// idempotent, only two *different* styles conflict. The flag spelling
    /// travels with the style so error messages name what was typed
    /// without switching over a domain that excludes `.full` (the
    /// unflagged default never joins the list).
    private static func appendStyle(
        _ style: DemangleStyle, flag: String,
        to styles: inout [(style: DemangleStyle, flag: String)],
    ) {
        if !styles.contains(where: { $0.style == style }) {
            styles.append((style, flag))
        }
    }

    /// Parse the arguments after the `census` verb. Census reads standard
    /// input only — positional arguments are rejected (they would be
    /// silently meaningless otherwise), as are the filter's style and
    /// output flags, each with a message naming why.
    private static func parseCensus(_ arguments: ArraySlice<String>) -> ParsedCommandLine {
        var invocation = CensusInvocation()
        var optionsEnded = false
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            index += 1
            if optionsEnded {
                return censusPositionalError(argument)
            }
            switch argument {
            case "--":
                optionsEnded = true
            case "--format":
                guard index < arguments.endIndex else {
                    return .usageError("swiftfilt: error: --format needs a value (bare, nm, or linkmap)")
                }
                guard let format = CensusFormat(rawValue: arguments[index]) else {
                    return .usageError("swiftfilt: error: unknown census format '\(arguments[index])' (expected bare, nm, or linkmap)")
                }
                invocation.format = format
                index += 1
            case "--top":
                guard index < arguments.endIndex else {
                    return .usageError("swiftfilt: error: --top needs a value (a positive row count)")
                }
                guard let top = Int(arguments[index]), top > 0 else {
                    return .usageError("swiftfilt: error: --top expects a positive row count, not '\(arguments[index])'")
                }
                invocation.top = top
                index += 1
            case "--jobs":
                guard index < arguments.endIndex else {
                    return .usageError("swiftfilt: error: --jobs needs a value (a positive thread count; 1 disables parallelism)")
                }
                guard let parsed = Int(arguments[index]), parsed >= 1 else {
                    return .usageError("swiftfilt: error: --jobs expects a positive thread count, not '\(arguments[index])'")
                }
                invocation.jobs = parsed
                index += 1
            case "--json":
                invocation.json = true
            case "--slim":
                invocation.slim = true
            case "--color":
                guard index < arguments.endIndex else {
                    return .usageError("swiftfilt: error: --color needs a value (auto, always, or never)")
                }
                guard let parsed = ColorMode(rawValue: arguments[index]) else {
                    return .usageError("swiftfilt: error: unknown color mode '\(arguments[index])' (expected auto, always, or never)")
                }
                invocation.color = parsed
                index += 1
            case "--simplified", "--qualified", "--unqualified":
                return .usageError("swiftfilt: error: \(argument) does not apply to census (the census aggregates symbols; it renders none)")
            case "--tree", "--classify":
                return .usageError("swiftfilt: error: \(argument) does not apply to census (census output is the report or --json)")
            default:
                if argument.hasPrefix("-") {
                    return .usageError("swiftfilt: error: unknown census option '\(argument)'")
                }
                return censusPositionalError(argument)
            }
        }
        if invocation.slim, !invocation.json {
            return .usageError("swiftfilt: error: --slim shapes --json output; add --json (or drop --slim)")
        }
        return .census(invocation)
    }

    /// The census-takes-no-arguments usage error.
    private static func censusPositionalError(_ argument: String) -> ParsedCommandLine {
        .usageError("swiftfilt: error: census reads standard input and takes no arguments (got '\(argument)'); pipe or redirect the listing in")
    }

    /// Parse the arguments after the `explain` verb. Explain takes symbol
    /// positionals and the `--json`/`--slim`/`--color` output flags; the
    /// filter/census-only flags are rejected with a message naming why,
    /// and `--` ends option parsing so a symbol starting with `-` (or the
    /// literal word `census`) can be explained.
    private static func parseExplain(_ arguments: ArraySlice<String>) -> ParsedCommandLine {
        var invocation = ExplainInvocation()
        var optionsEnded = false
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            index += 1
            if optionsEnded {
                invocation.symbols.append(argument)
                continue
            }
            switch argument {
            case "--":
                optionsEnded = true
            case "--json":
                invocation.json = true
            case "--slim":
                invocation.slim = true
            case "--color":
                guard index < arguments.endIndex else {
                    return .usageError("swiftfilt: error: --color needs a value (auto, always, or never)")
                }
                guard let parsed = ColorMode(rawValue: arguments[index]) else {
                    return .usageError("swiftfilt: error: unknown color mode '\(arguments[index])' (expected auto, always, or never)")
                }
                invocation.color = parsed
                index += 1
            case "--simplified", "--qualified", "--unqualified", "--tree", "--classify":
                return .usageError("swiftfilt: error: \(argument) does not apply to explain (explain prints every rendering already; use the default filter or symbol-args mode for one)")
            case "--jobs", "--format", "--top":
                return .usageError("swiftfilt: error: \(argument) does not apply to explain")
            default:
                if argument.hasPrefix("-") {
                    return .usageError("swiftfilt: error: unknown explain option '\(argument)' (use -- before symbols that start with -)")
                }
                invocation.symbols.append(argument)
            }
        }
        if invocation.slim, !invocation.json {
            return .usageError("swiftfilt: error: --slim shapes --json output; add --json (or drop --slim)")
        }
        // No symbol arguments is not an error: explain then reads standard
        // input, one symbol per line (the `nm | grep | swiftfilt explain`
        // shape), exactly as the bare filter and the demangler read stdin.
        return .explain(invocation)
    }
}
