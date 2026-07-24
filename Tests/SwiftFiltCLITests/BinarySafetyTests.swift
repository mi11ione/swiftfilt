// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import Foundation
import SwiftFiltCLICore
import Testing

/// The binary-safety contract: bytes not part of a validated mangling pass through byte-identical (invalid UTF-8, NULs, ANSI escapes, prefix lookalikes), with checked-in `.bin` fixtures as the hostile material.
@Suite("Binary-safe pass-through")
struct BinarySafetyTests {
    @Test func pureJunkPassesThroughByteIdentical() {
        let input = fixtureBytes(cliInputPath("pure-junk.bin"))
        #expect(!input.isEmpty, "fixture must exist")
        // The fixture is deliberately hostile: prefix lookalikes glued to
        // invalid UTF-8, no valid mangling anywhere, no trailing newline.
        let run = runCLI([], stdin: input)
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stdoutBytes == input)
        #expect(run.stderr.isEmpty)
    }

    @Test func pureJunkPassesThroughByteIdenticalUnderAnyChunking() {
        let input = fixtureBytes(cliInputPath("pure-junk.bin"))
        for size in [1, 3, 16, 1024] {
            #expect(runCLI([], stdin: input, chunkSize: size).stdoutBytes == input)
        }
    }

    @Test func pureJunkFixtureIsInvalidUTF8() {
        // Guard the fixture's reason to exist: it must NOT be valid UTF-8
        // (otherwise it tests nothing the text fixtures don't).
        let input = fixtureBytes(cliInputPath("pure-junk.bin"))
        #expect(String(bytes: input, encoding: .utf8) == nil)
    }

    @Test func mixedJunkRewritesSymbolsAndPreservesJunk() {
        let input = fixtureBytes(cliInputPath("mixed-junk.bin"))
        let run = runCLI([], stdin: input)
        #expect(run.stdoutBytes == goldenBytes("mixed-junk.full.bin"))
        // The junk bytes survive around the rewrites.
        #expect(run.stdoutBytes.contains(0xFF) && run.stdoutBytes.contains(0xF5))
        // The symbols were rewritten.
        let text = run.stdout
        #expect(text.contains("generic specialization <Swift.Int> of main.foo() -> ()"))
        #expect(text.contains("AppIntents.AppIntentsXPCError.errorCode.getter : Swift.Int"))
    }

    @Test func mixedJunkGoldenIsStableUnderChunking() {
        let input = fixtureBytes(cliInputPath("mixed-junk.bin"))
        for size in [1, 5, 64] {
            #expect(runCLI([], stdin: input, chunkSize: size).stdoutBytes == goldenBytes("mixed-junk.full.bin"))
        }
    }

    @Test func everyByteValueRoundTripsWhenNoManglingIsPresent() {
        // The full byte alphabet, including \n (which frames) and \0:
        // identity through the whole CLI pipeline.
        let input = (0 ... 255).map { UInt8($0) }
        let run = runCLI([], stdin: input, chunkSize: 7)
        #expect(run.stdoutBytes == input)
    }

    @Test func nulByteAdjacentSymbolStillRewrites() {
        var input: [UInt8] = [0x00]
        input.append(contentsOf: "$s4main3fooyyF".utf8)
        input.append(0x00)
        var expected: [UInt8] = [0x00]
        expected.append(contentsOf: "main.foo() -> ()".utf8)
        expected.append(0x00)
        #expect(runCLI([], stdin: input).stdoutBytes == expected)
    }

    @Test func invalidUTF8NeverReachesJSONOutput() throws {
        // JSON mode scans junk streams but emits only the (ASCII) mangled
        // names and their demanglings — the NDJSON stays valid UTF-8 even
        // when the input is not.
        let input = fixtureBytes(cliInputPath("mixed-junk.bin"))
        let run = runCLI(["--json"], stdin: input)
        #expect(run.status == CLI.exitSuccess)
        let text = try #require(String(bytes: run.stdoutBytes, encoding: .utf8), "NDJSON must be valid UTF-8")
        #expect(text.split(separator: "\n").count == 2)
    }
}
