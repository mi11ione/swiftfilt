// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt
import SwiftFiltCLICore
import Testing

/// The streaming contract: everything an input chunk completes is written before the next is read (live pipelines), and an over-window line is processed in bounded windows whose concatenation equals the unbounded-memory answer — with the one documented degradation for absurd unbroken runs.
@Suite("Streaming and bounded memory")
struct StreamingTests {
    let capacity = FilterStream.windowCapacity

    @Test func eachChunkFlushesWhatItCompletes() {
        // Three lines in one chunk: one batched write. The same three
        // lines a chunk apiece: three writes, one per completed line.
        let together = runCLI([], stdinText: "one $s4main3fooyyF\ntwo\nthree\n")
        #expect(together.outputCalls == 1, "one chunk, one batched write")
        #expect(together.stdout == "one main.foo() -> ()\ntwo\nthree\n")
        let lineSized = runCLI([], stdinText: "one $s4main3fooyyF\ntwo!\nthre\n", chunkSize: 5)
        // 19-byte first line arrives across chunks; every chunk carrying
        // a completed line produces exactly one write.
        #expect(lineSized.outputCalls == 3)
        #expect(lineSized.stdout == "one main.foo() -> ()\ntwo!\nthre\n")
    }

    @Test func outputBeginsBeforeEndOfInput() {
        // A tail -f pipeline never ends; output must not wait for EOF.
        // Serve three lines as three chunks and record whether the first
        // line was written before the last chunk was even requested.
        let chunks: [[UInt8]] = [
            Array("first $s4main3fooyyF\n".utf8),
            Array("second\n".utf8),
            Array("third\n".utf8),
        ]
        var next = 0
        var outputCallsWhenLastChunkServed = -1
        var out: [UInt8] = []
        var outputCalls = 0
        _ = CLI.run(
            arguments: [],
            input: {
                guard next < chunks.count else { return nil }
                defer { next += 1 }
                if next == chunks.count - 1 {
                    outputCallsWhenLastChunkServed = outputCalls
                }
                return chunks[next]
            },
            writeOutput: { bytes in
                out.append(contentsOf: bytes)
                outputCalls += 1
            },
            writeError: { _ in },
            standardOutputIsTTY: false,
        )
        #expect(outputCallsWhenLastChunkServed >= 2, "earlier lines must flush before later input arrives")
        #expect(String(decoding: out, as: UTF8.self) == "first main.foo() -> ()\nsecond\nthird\n")
    }

    // MARK: Over-window lines

    @Test func overWindowLineIsWindowedWithoutChangingTheOutput() {
        // One line half again the window size, symbols sprinkled before,
        // around, and after the window boundary — including one that
        // straddles it. Windowed streaming must equal the ground truth
        // (the library filter over the whole line at once).
        let symbol = "$s4main6ServerC5start4portySi_tF"
        var line = ""
        line.reserveCapacity(capacity + capacity / 2)
        line += "head " + symbol + " "
        line += String(repeating: "junk and words ", count: (capacity - 2048) / 15)
        // Pad so the next symbol straddles the window boundary exactly.
        line += String(repeating: "x", count: max(0, capacity - line.utf8.count + 8 - symbol.utf8.count))
        line += " " // break the run so the cut point sits just before the symbol region
        line += symbol
        line += " middle "
        line += String(repeating: "y", count: capacity / 4)
        line += " tail " + symbol + "\n"
        let input = Array(line.utf8)

        let expected = MangledNameScanner().demangleAll(inBytes: input)
        let run = runCLI([], stdin: input, chunkSize: 64 << 10)
        #expect(run.stdoutBytes == expected)
        #expect(run.outputCalls > 1, "an over-window line must flush in more than one piece")
    }

    @Test func overWindowLineJSONProvenanceStaysLineRelative() throws {
        // A symbol far past the window boundary still reports its true
        // byte offset within the (single) line.
        let symbol = "$s4main3fooyyF"
        let padding = String(repeating: "p q ", count: (capacity + 4096) / 4)
        let line = padding + symbol + "\n"
        let run = runCLI(["--json"], stdinText: line, chunkSize: 128 << 10)
        let record = run.stdout.split(separator: "\n").first
        let parsed = try #require(record)
        #expect(parsed.contains("\"line\":1"))
        #expect(parsed.contains("\"byteOffset\":\(padding.utf8.count)"))
    }

    @Test func jsonModeWindowsAnOverCapacityLineMidStream() throws {
        // The line runs a full megabyte PAST the window cap before its
        // newline arrives, so the JSON path must flush windows mid-line
        // (the match-printing window arm) — and the match found in a
        // LATER window still reports its line-relative byte offset
        // through the accumulated window base.
        let symbol = "$s4main3fooyyF"
        let padding = String(repeating: "p q ", count: (capacity + (1 << 20)) / 4)
        let line = padding + symbol + "\n"
        let run = runCLI(["--json"], stdinText: line, chunkSize: 256 << 10)
        let record = try #require(run.stdout.split(separator: "\n").first)
        #expect(record.contains("\"line\":1"))
        #expect(record.contains("\"byteOffset\":\(padding.utf8.count)"))
    }

    @Test func treeModeDiscardsAnOversizedRunAndResumesScanning() {
        // Tree mode meets the documented oversized-run degradation: the
        // run overshoots the window cap by half a megabyte BEFORE any
        // newline arrives (so the discard state actually engages), the
        // run's tail on the next framed line clears that state even when
        // the whole remainder is mangling characters, and the symbol
        // after it prints its tree normally. The run's bytes are never
        // printed — tree output is matches only.
        let head = String(repeating: "A", count: capacity + (1 << 19))
        let run = runCLI(["--tree"], stdinText: head + "AA\n$s4main3fooyyF\n", chunkSize: 256 << 10)
        #expect(run.stdout.hasPrefix("Demangling for $s4main3fooyyF"))
        #expect(run.stdout.contains("kind=Identifier, text=\"foo\""))
    }

    @Test func unbrokenOverWindowRunPassesThroughUnscanned() {
        // The documented degradation: a single mangling-character run
        // longer than the window is never rewritten — but it round-trips
        // byte-identically, and the stream after it filters normally.
        let run5MiB = String(repeating: "a", count: capacity + (1 << 20))
        let embedded = "$s4main3fooyyF"
        let input = "zz" + run5MiB + embedded + run5MiB + " then $s4main3fooyyF\n"
        let run = runCLI([], stdinText: input, chunkSize: 256 << 10)
        let expected = "zz" + run5MiB + embedded + run5MiB + " then main.foo() -> ()\n"
        #expect(run.stdout == expected)
    }

    @Test func justUnderWindowLineScansAsOnePiece() {
        // Control for the degradation test: the same shape under the cap
        // rewrites its embedded symbol.
        let run = String(repeating: "a", count: 1 << 16)
        let input = run + " $s4main3fooyyF " + run + "\n"
        let filtered = runCLI([], stdinText: input)
        #expect(filtered.stdout == run + " main.foo() -> () " + run + "\n")
    }

    @Test func windowedAndUnchunkedRunsAgreeOnBinaryFixtures() {
        // Chunking ± windowing is invisible on the hostile fixtures too.
        let input = fixtureBytes(cliInputPath("mixed-junk.bin"))
        let whole = runCLI([], stdin: input).stdoutBytes
        #expect(runCLI([], stdin: input, chunkSize: 2).stdoutBytes == whole)
    }

    @Test func windowCapacityIsFourMiB() {
        // The documented bound; a change is a deliberate contract change.
        #expect(FilterStream.windowCapacity == 4 << 20)
    }

    // MARK: Oversized-run discard choreography

    // Driving FilterStream directly pins the chunk shapes the documented degradation
    // must survive: the discard state from an over-window unbroken run must end at the
    // first run break — inside another over-capacity buffer, at its head, via a newline,
    // or never — with every byte round-tripping and scanning resuming at the break.

    private func filtered(_ chunks: [String]) -> String {
        var stream = FilterStream(mode: .rewrite(classify: false), style: .full, palette: Palette(enabled: false))
        var out: [UInt8] = []
        for chunk in chunks {
            stream.consume(Array(chunk.utf8)) { out.append(contentsOf: $0) }
        }
        stream.finish { out.append(contentsOf: $0) }
        return String(decoding: out, as: UTF8.self)
    }

    @Test func discardedRunEndsAtABreakInsideALaterOverCapacityBuffer() {
        // Chunk 1 starts the discard; chunk 2 is itself over capacity and
        // carries the run's break — bytes before the break pass through
        // raw, and the symbol after it scans normally.
        let head = String(repeating: "A", count: capacity + 1)
        let more = String(repeating: "A", count: 2 << 20)
        let tail = String(repeating: "B", count: capacity / 2)
        let out = filtered([head, more + " $s4main3fooyyF " + tail])
        #expect(out == head + more + " main.foo() -> () " + tail)
    }

    @Test func discardContinuesAcrossUnbrokenOverCapacityBuffers() {
        // The run just keeps going past capacity again: every byte passes
        // through raw, none is buffered, and the stream stays byte-exact.
        let run = String(repeating: "A", count: capacity + 1)
        let out = filtered([run, run])
        #expect(out == run + run)
    }

    @Test func discardBreakAtTheBufferHeadRejoinsNormalWindowing() {
        // The very first byte after the discarded run is the break: the
        // discard ends without flushing anything, and the rest of the
        // buffer windows normally down to the trailing symbol.
        let head = String(repeating: "A", count: capacity + 1)
        let quiet = String(repeating: "B", count: capacity)
        let out = filtered([head, " " + quiet + " $s4main3fooyyF"])
        #expect(out == head + " " + quiet + " main.foo() -> ()")
    }

    @Test func newlineEndsADiscardedRunEvenWhenTheLineRemainderIsAllRunBytes() {
        // The discarded run's line ends while every remaining byte is
        // still a mangling character; the newline itself is the break,
        // and the next line scans normally.
        let head = String(repeating: "A", count: capacity + 1)
        let out = filtered([head, "AA\n$s4main3fooyyF\n"])
        #expect(out == head + "AA\nmain.foo() -> ()\n")
    }

    @Test func atSignBeforeTheTrailingRunJoinsTheWindowCut() {
        // A `@` immediately before the trailing run could begin an
        // `@__swiftmacro_` candidate, so the cut moves before it; the
        // remaining `@`-led over-window run then passes through raw.
        let junk = String(repeating: "!", count: 100)
        let run = String(repeating: "x", count: capacity)
        let out = filtered([junk + "@" + run])
        #expect(out == junk + "@" + run)
    }
}
