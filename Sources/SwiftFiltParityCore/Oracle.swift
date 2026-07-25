// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// The live `swift-demangle` oracle: location, identity (recorded in every
// run's evidence), and batched invocation. Subprocess discipline, learned
// the hard way upstream: symbols stream through stdin in large batches
// (never per-symbol spawns), stdout and stderr drain CONCURRENTLY with the
// stdin write (a sequential drain deadlocks when the child floods one pipe
// before the other reaches EOF), and every invocation carries a kill
// timeout (SIGTERM at the deadline, SIGKILL five seconds later) because
// the oracle has a documented history of hanging on adversarial input.

import Foundation

public struct SubprocessResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let timedOut: Bool
}

/// Bridge one blocking pipe operation onto its own thread. The drains and
/// the stdin feed each block until EOF, which must not happen on a
/// cooperative-pool thread: that pool is sized to the core count, and three
/// blocked threads per child starve it once batches run concurrently.
private func onBlockingThread<T: Sendable>(_ body: @Sendable @escaping () -> T) async -> T {
    await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        Thread { continuation.resume(returning: body()) }.start()
    }
}

/// Feed the child's stdin and close it, so its reader sees EOF.
private func feedStdin(_ pipe: Pipe?, _ data: Data?) async {
    guard let pipe, let data else { return }
    let handle = pipe.fileHandleForWriting
    await onBlockingThread {
        // Feed via raw POSIX write(2): a child that closes its stdin early
        // returns EPIPE here, which we treat as a short write. Foundation's
        // FileHandle.write(_:) instead wraps that EPIPE in a `try!` that traps
        // the whole process (the SIGPIPE ignore below stops the signal, not
        // the trap).
        let fd = handle.fileDescriptor
        data.withUnsafeBytes { raw in
            guard var base = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, base, remaining)
                if n > 0 {
                    base = base.advanced(by: n)
                    remaining -= n
                } else if n < 0, errno == EINTR {
                    continue
                } else {
                    break // EPIPE (child gone) or other error: stop feeding
                }
            }
        }
        try? handle.close()
    }
}

/// Run `launchPath args...`, feeding `stdin`, draining both output pipes
/// concurrently with the write. Returns `nil` only when the process cannot
/// be launched at all; a timeout returns a result with `timedOut` set.
public func runSubprocess(
    _ launchPath: String,
    _ args: [String],
    stdin: Data? = nil,
    timeoutSeconds: Double = 120,
) async -> SubprocessResult? {
    // Process and Pipe are Sendable, and the legs below divide them cleanly:
    // each pipe end is touched by exactly one task, and the watchdog only
    // calls the process's own thread-safe terminate/isRunning/waitUntilExit.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = args

    // A child that closes its stdin early makes the feed hit EPIPE; ignore
    // SIGPIPE so that surfaces as a write error (handled) rather than a fatal
    // signal. Set here so the oracle is robust whether it is driven by the
    // tool's entry point or directly by a parity test.
    signal(SIGPIPE, SIG_IGN)

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    let inPipe: Pipe? = stdin.map { _ in Pipe() }
    if let inPipe {
        process.standardInput = inPipe
    }

    do {
        try process.run()
    } catch {
        return nil
    }

    // Feed and drain concurrently: a sequential drain deadlocks when the child
    // floods one pipe before the other reaches EOF.
    async let fed: Void = feedStdin(inPipe, stdin)
    async let outData: Data = onBlockingThread { outPipe.fileHandleForReading.readDataToEndOfFile() }
    async let errData: Data = onBlockingThread { errPipe.fileHandleForReading.readDataToEndOfFile() }

    // Watchdog: SIGTERM at the deadline (a chance to exit cleanly), SIGKILL
    // for a child that ignores it. Racing it against the child's own exit
    // means "did the deadline kill this?" arrives as the winner's value —
    // there is no flag for the two to race over. The group awaits both legs,
    // so the child is always reaped by the time this returns.
    let sigkillGraceSeconds = 5.0
    let killedByWatchdog = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await onBlockingThread { process.waitUntilExit() }
            return false
        }
        group.addTask {
            guard await (try? Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))) != nil
            else { return false } // cancelled: the child exited on its own
            guard process.isRunning else { return false } // exited right on the deadline
            process.terminate()
            if await (try? Task.sleep(nanoseconds: UInt64(sigkillGraceSeconds * 1_000_000_000))) != nil,
               process.isRunning
            {
                kill(process.processIdentifier, SIGKILL)
            }
            return true
        }
        let winner = await group.next() ?? false
        group.cancelAll()
        return winner
    }

    // Only a child that outlived the deadline AND died of a signal timed out.
    // A child killed by some unrelated signal must not be reported as one:
    // callers discard an entire timed-out run as unusable.
    let timedOut = killedByWatchdog && process.terminationReason == .uncaughtSignal

    await fed
    // Lenient decode: one non-UTF8 byte must not blank a multi-MB capture.
    return await SubprocessResult(
        stdout: String(decoding: outData, as: UTF8.self),
        stderr: String(decoding: errData, as: UTF8.self),
        exitCode: process.terminationStatus,
        timedOut: timedOut,
    )
}

// MARK: - swift-demangle

public enum Oracle {
    /// The tool path from `xcrun -f swift-demangle`, or `nil` when no
    /// toolchain is installed.
    public static func locate() async -> String? {
        guard let result = await runSubprocess("/usr/bin/xcrun", ["-f", "swift-demangle"], timeoutSeconds: 30),
              result.exitCode == 0
        else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// The oracle's identity for evidence records. `swift-demangle` has no
    /// version flag of its own; the sibling `swift` reports the
    /// `swiftlang-X.Y.Z…` build token that pins the toolchain exactly.
    public static func identity(_ swiftDemanglePath: String) async -> String {
        let swiftBin = (swiftDemanglePath as NSString).deletingLastPathComponent + "/swift"
        if let result = await runSubprocess(swiftBin, ["--version"], timeoutSeconds: 30), result.exitCode == 0 {
            if let range = result.stdout.range(of: "swiftlang-") {
                let token = result.stdout[range.lowerBound...].prefix { $0 != " " && $0 != ")" && $0 != "\n" }
                return String(token)
            }
            if let firstLine = result.stdout.split(separator: "\n").first {
                return String(firstLine)
            }
        }
        return "swift-demangle (version unknown)"
    }

    /// The five oracle output modes the live legs diff against, one entry
    /// per input symbol in batch order. Empty entries mean the oracle
    /// produced no output for that slot.
    public struct BatchOutputs: Sendable {
        /// `-tree-only -compact`: one node-tree block per symbol
        /// (`""` / `<<NULL>>`-containing when the oracle declined).
        public let tree: [String]
        /// Plain `-compact` — the `.full` target.
        public let compact: [String]
        /// `-simplified` — the `.simplified` target.
        public let simplified: [String]
        /// `-no-sugar` — the `.qualified` target.
        public let noSugar: [String]
        /// `-classify` — the `{N|T:target|C}` marker target.
        public let classify: [String]
    }

    /// Which oracle modes a run needs (each is one subprocess per batch).
    public struct Modes: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let tree = Modes(rawValue: 1 << 0)
        public static let compact = Modes(rawValue: 1 << 1)
        public static let simplified = Modes(rawValue: 1 << 2)
        public static let noSugar = Modes(rawValue: 1 << 3)
        public static let classify = Modes(rawValue: 1 << 4)
        public static let all: Modes = [.tree, .compact, .simplified, .noSugar, .classify]
    }

    /// Invoke the oracle over one batch in every requested mode. Returns
    /// `nil` on any invocation timeout, line-count misalignment, or launch
    /// failure — a whole-batch oracle failure is a harness/setup problem
    /// the caller aborts on loudly, never a parser divergence.
    public static func fetch(
        _ symbols: [String], oracle: String, modes: Modes, timeout: Double,
    ) async -> BatchOutputs? {
        let empty = [String](repeating: "", count: symbols.count)
        var tree = empty
        if modes.contains(.tree) {
            guard let proc = await runSubprocess(oracle, ["-tree-only", "-compact"], stdin: sentinelStdinData(symbols), timeoutSeconds: timeout),
                  !proc.timedOut,
                  let blocks = splitTreeBlocks(proc.stdout, symbols: symbols)
            else { return nil }
            tree = blocks
        }
        func mode(_ flag: [String], _ wanted: Bool) async -> [String]? {
            guard wanted else { return empty }
            return await lines(symbols, oracle: oracle, flags: flag, timeout: timeout)
        }
        guard let compact = await mode(["-compact"], modes.contains(.compact)),
              let simplified = await mode(["-simplified"], modes.contains(.simplified)),
              let noSugar = await mode(["-no-sugar"], modes.contains(.noSugar)),
              let classify = await mode(["-classify"], modes.contains(.classify))
        else { return nil }
        return BatchOutputs(tree: tree, compact: compact, simplified: simplified, noSugar: noSugar, classify: classify)
    }

    private static func stdinData(_ symbols: [String]) -> Data {
        Data((symbols.joined(separator: "\n") + "\n").utf8)
    }

    /// The tree-mode row boundary: a line with no mangling prefix anywhere,
    /// so the filter is guaranteed to echo it verbatim. It segments the
    /// stream exactly — the tool emits one `Demangling for <span>` block
    /// PER SPAN it finds in a line (a C name like `_TIS…Mode:._TISModeArray`
    /// yields a partial-span header), so header prediction alone cannot
    /// align a batch; sentinels can, under any span behavior.
    public static let treeRowSentinel = "----swiftfilt-parity-row-boundary----"

    private static func sentinelStdinData(_ symbols: [String]) -> Data {
        var text = ""
        text.reserveCapacity(symbols.reduce(0) { $0 + $1.utf8.count } + symbols.count * (treeRowSentinel.utf8.count + 2))
        for symbol in symbols {
            text += symbol + "\n" + treeRowSentinel + "\n"
        }
        return Data(text.utf8)
    }

    /// Run the oracle with `flags` over the batch on stdin, returning one
    /// output line per input symbol (the oracle emits 1:1), or `nil` when
    /// the line count does not match — a misaligned batch must abort, not
    /// silently mis-attribute verdicts.
    public static func lines(_ symbols: [String], oracle: String, flags: [String], timeout: Double) async -> [String]? {
        guard let proc = await runSubprocess(oracle, flags, stdin: stdinData(symbols), timeoutSeconds: timeout),
              !proc.timedOut
        else { return nil }
        var lines = proc.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines.count == symbols.count ? lines : nil
    }

    /// Split sentinel-segmented `swift-demangle -tree-only` output into one
    /// tree block per input symbol. Each input row's output is everything
    /// up to its sentinel echo; a row qualifies as a WHOLE-NAME tree only
    /// when its segment is exactly one header covering the entire name —
    /// `Demangling for <name>`, `Demangling for <stripped>`, or the filter
    /// form `_Demangling for <stripped>` (the tool strips one leading
    /// underscore from a `__…` name; in stdin mode the residual `_` is
    /// glued onto the header) — followed by real `kind=` lines. Everything
    /// else (echo, `<<NULL>>`, partial-span headers from lines the tool
    /// only demangles piecewise) yields "" — the whole name did not
    /// demangle as a unit, so there is no tree to compare. Returns nil
    /// when the sentinel count does not match the batch — malformed oracle
    /// output the caller aborts on loudly, never a guessed alignment.
    public static func splitTreeBlocks(_ output: String, symbols: [String]) -> [String]? {
        var blocks = [String](repeating: "", count: symbols.count)
        var segment: [String] = []
        var row = 0
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == treeRowSentinel {
                guard row < symbols.count else { return nil }
                blocks[row] = wholeNameTree(from: segment, symbol: symbols[row])
                segment.removeAll(keepingCapacity: true)
                row += 1
            } else {
                segment.append(String(line))
            }
        }
        guard row == symbols.count else { return nil }
        return blocks
    }

    /// The whole-name tree in one row's segment, or "" when the row has
    /// none (see ``splitTreeBlocks(_:symbols:)``). `<<NULL>>` bodies come
    /// back verbatim so the caller's decline rule sees them.
    private static func wholeNameTree(from segment: [String], symbol: String) -> String {
        var lines = segment[...]
        while lines.first?.isEmpty == true {
            lines = lines.dropFirst()
        }
        while lines.last?.isEmpty == true {
            lines = lines.dropLast()
        }
        let stripped = symbol.hasPrefix("__") ? String(symbol.dropFirst()) : symbol
        guard let header = lines.first,
              header == "Demangling for " + symbol || header == "Demangling for " + stripped
              || (symbol != stripped && header == "_Demangling for " + stripped)
        else { return "" }
        let body = lines.dropFirst()
        guard !body.isEmpty,
              body.allSatisfy({ $0.hasPrefix("kind=") || $0.hasPrefix(" ") || $0 == "<<NULL>>" })
        else { return "" }
        return body.joined(separator: "\n")
    }
}
