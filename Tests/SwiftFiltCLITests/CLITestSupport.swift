// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// Shared support for the CLI suites: fixture path resolution, an
// in-process CLI runner with injected stdio (chunked any way a test
// likes), and byte/string golden loading.

import Foundation
import SwiftFiltCLICore

/// Absolute path of a checked-in fixture under `Tests/Fixtures/CLI/input`,
/// resolved relative to this source file so `swift test` finds it
/// regardless of the working directory.
func cliInputPath(_ name: String) -> String {
    cliFixturesRoot + "/input/" + name
}

/// Absolute path of a locked golden file under `Tests/Fixtures/CLI/golden`.
func cliGoldenPath(_ name: String) -> String {
    cliFixturesRoot + "/golden/" + name
}

/// Absolute path of `Tests/Fixtures/CLI`.
let cliFixturesRoot: String = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // SwiftFiltCLITests
    .deletingLastPathComponent() // Tests
    .appendingPathComponent("Fixtures/CLI").path

/// Absolute path of a checked-in census fixture (the real LinkMap and nm
/// dumps `Scripts/build-census-fixtures.sh` regenerates).
func censusFixturePath(_ name: String) -> String {
    URL(fileURLWithPath: cliFixturesRoot)
        .deletingLastPathComponent() // Fixtures
        .appendingPathComponent("Census/\(name)").path
}

/// The raw bytes of a fixture file (empty if missing; the tests that use
/// this assert on content, so a missing fixture fails loudly there).
func fixtureBytes(_ path: String) -> [UInt8] {
    let data = FileManager.default.contents(atPath: path) ?? Data()
    return [UInt8](data)
}

/// A fixture file as a UTF-8 string.
func fixtureString(_ path: String) -> String {
    String(decoding: fixtureBytes(path), as: UTF8.self)
}

/// The locked golden bytes for `name`.
func goldenBytes(_ name: String) -> [UInt8] {
    fixtureBytes(cliGoldenPath(name))
}

/// The locked golden string for `name`.
func golden(_ name: String) -> String {
    fixtureString(cliGoldenPath(name))
}

/// One captured CLI invocation: exit status, raw stdout bytes, the same
/// decoded as UTF-8 for text assertions, everything written to stderr,
/// and how many times the output sink was called (the flush count — one
/// call per completed line is the streaming contract).
struct CLIRun {
    let status: Int32
    let stdoutBytes: [UInt8]
    let stderr: String
    let outputCalls: Int

    var stdout: String {
        String(decoding: stdoutBytes, as: UTF8.self)
    }
}

/// Run `CLI.run` in-process with the given argv and stdin bytes, capturing
/// both sinks. `chunkSize` slices the input to exercise framing across
/// chunk boundaries (`nil` hands everything as one chunk).
func runCLI(
    _ arguments: [String],
    stdin: [UInt8] = [],
    chunkSize: Int? = nil,
    tty: Bool = false,
    fileExists: @escaping (String) -> Bool = { _ in false },
) -> CLIRun {
    var chunks: [[UInt8]] = []
    if let chunkSize, chunkSize > 0 {
        var start = 0
        while start < stdin.count {
            let end = min(start + chunkSize, stdin.count)
            chunks.append(Array(stdin[start ..< end]))
            start = end
        }
    } else if !stdin.isEmpty {
        chunks = [stdin]
    }
    var next = 0
    var out: [UInt8] = []
    var calls = 0
    var err = ""
    let status = CLI.run(
        arguments: arguments,
        input: {
            guard next < chunks.count else { return nil }
            defer { next += 1 }
            return chunks[next]
        },
        writeOutput: { bytes in
            out.append(contentsOf: bytes)
            calls += 1
        },
        writeError: { err += $0 },
        standardOutputIsTTY: tty,
        fileExists: fileExists,
    )
    return CLIRun(status: status, stdoutBytes: out, stderr: err, outputCalls: calls)
}

/// Run the CLI on string stdin (the common text-fixture case).
func runCLI(
    _ arguments: [String],
    stdinText: String,
    chunkSize: Int? = nil,
    tty: Bool = false,
) -> CLIRun {
    runCLI(arguments, stdin: Array(stdinText.utf8), chunkSize: chunkSize, tty: tty)
}

/// Spawn `toolPath` with `arguments`, feed it `stdin`, and return its exit
/// status and stdout bytes (stderr discarded). stdout is drained on a reader
/// thread so a tool that out-writes the ~64 KiB pipe buffer cannot deadlock,
/// and stdin is fed with raw POSIX `write(2)`: a child that closes its input
/// early surfaces as a short write, never the fatal `try!`-on-EPIPE buried in
/// Foundation's `FileHandle.write(contentsOf:)`. Shared by the jq and
/// `swift-demangle` oracle suites — the CI-portable way to drive a subprocess.
func runTool(_ toolPath: String, _ arguments: [String], stdin: [UInt8]) throws -> (status: Int32, stdout: [UInt8]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: toolPath)
    process.arguments = arguments
    let inPipe = Pipe()
    let outPipe = Pipe()
    process.standardInput = inPipe
    process.standardOutput = outPipe
    process.standardError = FileHandle.nullDevice
    signal(SIGPIPE, SIG_IGN)
    try process.run()

    final class Landing: @unchecked Sendable { var bytes = Data() }
    let drained = Landing()
    let reader = Thread { drained.bytes = outPipe.fileHandleForReading.readDataToEndOfFile() }
    reader.start()

    let fd = inPipe.fileHandleForWriting.fileDescriptor
    stdin.withUnsafeBytes { raw in
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
                break // EPIPE (child already gone) or other error: nothing more to feed
            }
        }
    }
    try? inPipe.fileHandleForWriting.close()

    process.waitUntilExit()
    while !reader.isFinished {
        usleep(1000)
    }
    return (process.terminationStatus, [UInt8](drained.bytes))
}
