// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// Workload construction: the deterministic symbol stream (bundled
// fixtures or the external corpus manifest), the synthetic log buffer
// for the filter benchmark, the one-spawn-per-batch subprocess oracle,
// and the dlsym(swift_demangle) runtime hook — the two comparison
// engines the README table cites.

import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

// MARK: - Symbol stream

/// Where the benchmark's symbols came from — printed into the run's
/// config so recorded numbers name their input.
struct SymbolStream {
    let symbols: [String]
    let sourceDescription: String
}

/// Load the symbol stream: `SWIFTFILT_DEMANGLE_CORPUS` (a manifest of
/// `mangled<TAB>first_binary<TAB>occurrences` rows) when set, otherwise
/// the repository's committed fixture corpora — 10,845 real-world
/// mangled names (corpus.tsv + apple.tsv + legacy.tsv, first column),
/// in file order, so the default stream is fully deterministic.
func loadSymbolStream(cap: Int?) -> SymbolStream {
    if let manifest = ProcessInfo.processInfo.environment["SWIFTFILT_DEMANGLE_CORPUS"] {
        guard let text = try? String(contentsOfFile: manifest, encoding: .utf8) else {
            fatalError("swiftfilt-bench: cannot read SWIFTFILT_DEMANGLE_CORPUS at \(manifest)")
        }
        var symbols: [String] = []
        for line in text.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            symbols.append(String(line[..<tab]))
            if let cap, symbols.count >= cap { break }
        }
        return SymbolStream(
            symbols: symbols,
            sourceDescription: "external corpus \(manifest) (\(symbols.count) rows)",
        )
    }
    let fixturesDir = repositoryFixturesDirectory()
    var symbols: [String] = []
    for file in ["corpus.tsv", "apple.tsv", "legacy.tsv"] {
        let path = fixturesDir + "/" + file
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            fatalError("swiftfilt-bench: cannot read the bundled fixture corpus at \(path)")
        }
        for line in text.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            symbols.append(String(line[..<tab]))
        }
    }
    if let cap, symbols.count > cap { symbols.removeLast(symbols.count - cap) }
    return SymbolStream(
        symbols: symbols,
        sourceDescription: "bundled fixtures (corpus+apple+legacy, \(symbols.count) rows)",
    )
}

/// The repo's fixture directory: resolved from this source file's
/// compile-time path (build and run happen on the same checkout), with
/// cwd-relative fallbacks for a relocated binary.
func repositoryFixturesDirectory() -> String {
    let fromSource = URL(fileURLWithPath: #filePath) // …/Benchmarks/Sources/swiftfilt-bench/Workloads.swift
        .deletingLastPathComponent() // swiftfilt-bench
        .deletingLastPathComponent() // Sources
        .deletingLastPathComponent() // Benchmarks
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("Tests/Fixtures/SwiftDemangling").path
    for candidate in [fromSource, "../Tests/Fixtures/SwiftDemangling", "Tests/Fixtures/SwiftDemangling"] {
        if FileManager.default.fileExists(atPath: candidate + "/corpus.tsv") {
            return candidate
        }
    }
    fatalError("swiftfilt-bench: fixture corpus not found (run from the repo, or set SWIFTFILT_DEMANGLE_CORPUS)")
}

// MARK: - Synthetic log

/// A deterministic synthetic build/crash log of at least `byteCount`
/// bytes (whole lines, so the size overshoots by at most one line).
/// Line recipe, cycled 4-at-a-time with SplitMix64 picking symbols:
///   1. a crash-frame line (`N  Module  0xADDR  <symbol> + off`),
///   2. a prose build line (no manglings),
///   3. an nm-style line (`ADDR T <symbol>`, the name verbatim),
///   4. a hex/number noise line (the scanner must reject it fast).
/// Half the LINES carry one mangled name each, but most of the buffer's
/// BYTES are non-symbol text — the density of a real crash log's frame
/// section amortized over its headers, and what makes MB/s the
/// meaningful unit.
func makeSyntheticLog(byteCount: Int, seed: UInt64, symbols: [String]) -> [UInt8] {
    precondition(!symbols.isEmpty)
    var rng = SplitMix64(seed: seed)
    var out: [UInt8] = []
    out.reserveCapacity(byteCount + 256)
    var frame = 0
    while out.count < byteCount {
        let symbolA = symbols[Int(rng.next() % UInt64(symbols.count))]
        let symbolB = symbols[Int(rng.next() % UInt64(symbols.count))]
        let addr = rng.next()
        let line1 = "\(frame % 512)   MyApp                         0x\(String(addr | 0x1_0000_0000, radix: 16)) \(symbolA) + \(addr % 4096)\n"
        let line2 = "Compiling Sources/App/Feature\(addr % 97).swift — emitting module interface, this line carries no symbols at all\n"
        let line3 = "\(String(format: "%016llx", addr)) T \(symbolB)\n"
        let line4 = "raw words: 0x\(String(rng.next(), radix: 16)) 0x\(String(rng.next(), radix: 16)) \(rng.next() % 100_000)\n"
        out.append(contentsOf: line1.utf8)
        out.append(contentsOf: line2.utf8)
        out.append(contentsOf: line3.utf8)
        out.append(contentsOf: line4.utf8)
        frame += 4
    }
    return out
}

// MARK: - Raw subprocess substrate

/// What the child's stdin is connected to.
enum SpawnStdin {
    case null
    case data(Data)
    case path(String)
}

/// Whether a child output stream is captured or discarded.
enum SpawnCapture {
    case capture
    case null
}

/// Mutable byte sink a drain thread fills (joined before use).
private final class DrainBox: @unchecked Sendable {
    var data = Data()
}

/// Raw `posix_spawn` + `waitpid` subprocess run. The benchmark rows
/// MUST NOT use Foundation's `Process`: its spawn/exit machinery adds a
/// fixed latency measured at ~65 ms per spawn on this OS (vs ~1.5 ms
/// raw — verified against `posix_spawnp`/`waitpid` and a shell loop),
/// which would bill harness overhead to the subprocess contenders.
/// Stdin data writes on a dedicated thread and captured streams drain
/// concurrently — a child that floods a pipe before stdin EOF deadlocks
/// any sequential drain. Returns nil on spawn failure; `status` is the
/// child's exit code (-1 when signaled).
func spawnSubprocess(
    path: String,
    arguments: [String],
    stdin stdinSource: SpawnStdin,
    stdout stdoutMode: SpawnCapture,
    stderr stderrMode: SpawnCapture = .null,
) -> (status: Int32, stdout: Data, stderr: Data)? {
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    #if canImport(Darwin)
        // Child inherits ONLY the three stdio slots below.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
    #endif

    func makePipe() -> (read: Int32, write: Int32)? {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        return (fds[0], fds[1])
    }

    var parentFDs: [Int32] = []
    var childFDs: [Int32] = []
    defer { parentFDs.forEach { _ = close($0) } }

    var stdinWriteFD: Int32 = -1
    switch stdinSource {
    case .null:
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    case let .path(file):
        posix_spawn_file_actions_addopen(&actions, 0, file, O_RDONLY, 0)
    case .data:
        guard let p = makePipe() else { return nil }
        posix_spawn_file_actions_adddup2(&actions, p.read, 0)
        childFDs.append(p.read)
        stdinWriteFD = p.write
        #if canImport(Darwin)
            // A child that exits early must not SIGPIPE the harness.
            _ = fcntl(p.write, F_SETNOSIGPIPE, 1)
        #endif
    }
    var stdoutReadFD: Int32 = -1
    switch stdoutMode {
    case .null:
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    case .capture:
        guard let p = makePipe() else { return nil }
        posix_spawn_file_actions_adddup2(&actions, p.write, 1)
        childFDs.append(p.write)
        stdoutReadFD = p.read
        parentFDs.append(p.read)
    }
    var stderrReadFD: Int32 = -1
    switch stderrMode {
    case .null:
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    case .capture:
        guard let p = makePipe() else { return nil }
        posix_spawn_file_actions_adddup2(&actions, p.write, 2)
        childFDs.append(p.write)
        stderrReadFD = p.read
        parentFDs.append(p.read)
    }

    var argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) }
    argv.append(nil)
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let spawnRC = posix_spawn(&pid, path, &actions, &attr, &argv, environ)
    childFDs.forEach { _ = close($0) }
    guard spawnRC == 0 else {
        if stdinWriteFD >= 0 { _ = close(stdinWriteFD) }
        return nil
    }

    @Sendable func drain(_ fd: Int32, into box: DrainBox) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                box.data.append(contentsOf: buffer[0 ..< n])
            } else if n == 0 || errno != EINTR {
                return
            }
        }
    }

    let writerDone = DispatchSemaphore(value: 0)
    if case let .data(payload) = stdinSource {
        let fd = stdinWriteFD
        Thread.detachNewThread {
            payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n > 0 {
                        offset += n
                    } else if errno != EINTR {
                        break // EPIPE: the child stopped reading
                    }
                }
            }
            _ = close(fd)
            writerDone.signal()
        }
    } else {
        writerDone.signal()
    }

    let stderrBox = DrainBox()
    let stderrDone = DispatchSemaphore(value: 0)
    if stderrReadFD >= 0 {
        let fd = stderrReadFD
        Thread.detachNewThread {
            drain(fd, into: stderrBox)
            stderrDone.signal()
        }
    } else {
        stderrDone.signal()
    }

    let stdoutBox = DrainBox()
    if stdoutReadFD >= 0 {
        drain(stdoutReadFD, into: stdoutBox)
    }
    writerDone.wait()
    stderrDone.wait()

    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0, errno == EINTR {}
    let exitCode: Int32 = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : -1
    return (exitCode, stdoutBox.data, stderrBox.data)
}

// MARK: - Subprocess comparison engine

/// One spawn per measured batch: every symbol through the tool's stdin,
/// one output line per input line (`swift-demangle`'s filter contract).
struct SubprocessDemangler {
    let path: String

    /// `swift-demangle` located like the parity instrument locates it:
    /// PATH, next to swiftc, then xcrun. `nil` when no toolchain is
    /// installed (the comparison reports itself unavailable).
    static func locate() -> SubprocessDemangler? {
        if let found = which("swift-demangle") {
            return SubprocessDemangler(path: found)
        }
        if let swiftc = which("swiftc") {
            let sibling = (swiftc as NSString).deletingLastPathComponent + "/swift-demangle"
            if FileManager.default.isExecutableFile(atPath: sibling) {
                return SubprocessDemangler(path: sibling)
            }
        }
        if let xcrun = which("xcrun"),
           let probe = spawnSubprocess(path: xcrun, arguments: ["-f", "swift-demangle"], stdin: .null, stdout: .capture),
           probe.status == 0
        {
            let path = String(decoding: probe.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if FileManager.default.isExecutableFile(atPath: path) {
                return SubprocessDemangler(path: path)
            }
        }
        return nil
    }

    private static func which(_ tool: String) -> String? {
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = String(dir) + "/" + tool
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Demangle the batch (spawn, write stdin, drain, wait) and return
    /// the number of output lines — the per-run work whose wall time the
    /// benchmark records. Returns `nil` on a spawn or line-count failure.
    func demangleBatch(_ stdinData: Data, expectedLines: Int) -> Int? {
        guard let run = spawnSubprocess(path: path, arguments: ["-compact"], stdin: .data(stdinData), stdout: .capture),
              run.status == 0 else { return nil }
        var lines = 0
        var checksum: UInt64 = 0
        for byte in run.stdout {
            checksum = checksum &* 31 &+ UInt64(byte)
            if byte == UInt8(ascii: "\n") { lines += 1 }
        }
        blackhole(checksum)
        return lines == expectedLines ? lines : nil
    }

    /// Demangle names passed as ARGUMENTS (`swift-demangle -compact
    /// [extraFlags] <names…>`) and return the output lines — the
    /// whole-name path the coverage census grades (the tool echoes a
    /// name it declines). `nil` on spawn failure or non-zero exit.
    func demangleArguments(_ names: [String], extraFlags: [String] = []) -> [String]? {
        guard let run = spawnSubprocess(path: path, arguments: ["-compact"] + extraFlags + names, stdin: .null, stdout: .capture),
              run.status == 0 else { return nil }
        return String(decoding: run.stdout, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast() // the trailing newline's empty tail
            .map(String.init)
    }
}

// MARK: - Runtime-hook comparison engine

/// The Swift runtime's own `swift_demangle` entry point, resolved with
/// dlsym from the already-loaded libswiftCore — the hook crash
/// reporters embed. String-only, no options, and its output shape is
/// whatever the running runtime prints; measured here purely as an
/// engine, one call per symbol, `free`ing each malloc'd result.
struct RuntimeHookDemangler {
    typealias Fn = @convention(c) (
        UnsafePointer<CChar>?, Int,
        UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32,
    ) -> UnsafeMutablePointer<CChar>?

    let fn: Fn

    static func locate() -> RuntimeHookDemangler? {
        #if canImport(Darwin)
            let handle = dlopen(nil, RTLD_NOW)
        #else
            let handle = dlopen(nil, RTLD_NOW)
        #endif
        guard let handle, let raw = dlsym(handle, "swift_demangle") else { return nil }
        return RuntimeHookDemangler(fn: unsafeBitCast(raw, to: Fn.self))
    }

    /// Demangle one symbol; `nil` when the runtime declines it.
    func demangle(_ mangled: String) -> Int? {
        mangled.withCString { cString -> Int? in
            guard let result = fn(cString, strlen(cString), nil, nil, 0) else { return nil }
            let length = strlen(result)
            blackhole(UInt64(length) &+ UInt64(bitPattern: Int64(result[0])))
            free(result)
            return length
        }
    }

    /// Demangle one symbol to its output STRING — the coverage census
    /// byte-compares it (the timed rows use `demangle(_:)`, which never
    /// materializes a Swift `String`).
    func demangledString(_ mangled: String) -> String? {
        mangled.withCString { cString -> String? in
            guard let result = fn(cString, strlen(cString), nil, nil, 0) else { return nil }
            defer { free(result) }
            return String(cString: result)
        }
    }
}

// MARK: - CLI wall measurement support

/// The repo's release `swiftfilt` binary for the CLI-wall rows, resolved
/// like the fixtures (this checkout's `.build/release/swiftfilt`).
/// `nil` — with the exact build command in the caller's skip note — when
/// it has not been built.
func locateSwiftfiltCLI() -> String? {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // swiftfilt-bench
        .deletingLastPathComponent() // Sources
        .deletingLastPathComponent() // Benchmarks
        .deletingLastPathComponent() // repo root
        .path
    let candidate = repoRoot + "/.build/release/swiftfilt"
    return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
}

/// Run one CLI contender over `stdinPath` (stdout → /dev/null), return
/// wall seconds. `nil` on spawn failure or non-zero exit.
func runCLIPass(binary: String, arguments: [String], stdinPath: String) -> Double? {
    var ok = false
    let wall = timed {
        if let run = spawnSubprocess(path: binary, arguments: arguments, stdin: .path(stdinPath), stdout: .null),
           run.status == 0
        {
            ok = true
        }
    }
    return ok ? wall : nil
}

/// One extra unrecorded pass under `/usr/bin/time -l` to read the CLI
/// child's peak resident set ("maximum resident set size", bytes on
/// Darwin). `nil` when the wrapper or the parse fails — the row then
/// omits child RSS honestly.
func measureCLIChildPeakRSS(binary: String, arguments: [String], stdinPath: String) -> UInt64? {
    guard let run = spawnSubprocess(
        path: "/usr/bin/time", arguments: ["-l", binary] + arguments,
        stdin: .path(stdinPath), stdout: .null, stderr: .capture,
    ), run.status == 0 else { return nil }
    for line in String(decoding: run.stderr, as: UTF8.self).split(separator: "\n")
        where line.contains("maximum resident set size")
    {
        let digits = line.prefix(while: { $0 == " " || $0.isNumber }).trimmingCharacters(in: .whitespaces)
        return UInt64(digits)
    }
    return nil
}
