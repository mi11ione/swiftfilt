// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// Reading standard input as a list of whole-line inputs — the shape the
// `explain` verb and `--type` mode share when they run without arguments:
// each line is one symbol / one type string, exactly as `nm | grep …` emits
// them. Batch, not a streaming rewrite: these modes are per-record and
// verbose, so the whole (bounded) list is read, then each record processed.

/// Standard-input line reading for the argument-shaped modes.
enum StreamLines {
    /// Every non-empty line of the injected byte input, in order. Chunks are
    /// concatenated, split on `\n` (a trailing `\r` of a CRLF line dropped),
    /// and each line decoded as UTF-8 (an invalid byte becomes U+FFFD — a
    /// garbage line is diagnosed by the caller, never a crash). Empty lines
    /// are skipped, so a trailing newline (or a blank separator between
    /// symbols) contributes no record.
    static func read(_ input: () -> [UInt8]?) -> [String] {
        var bytes: [UInt8] = []
        while let chunk = input() {
            bytes.append(contentsOf: chunk)
        }
        var lines: [String] = []
        var start = 0
        var index = 0
        let count = bytes.count
        while index < count {
            if bytes[index] == 0x0A {
                append(bytes, from: start, upTo: index, into: &lines)
                start = index + 1
            }
            index += 1
        }
        if start < count {
            append(bytes, from: start, upTo: count, into: &lines)
        }
        return lines
    }

    /// Decode `bytes[from..<upTo]` (dropping a trailing CR) and append it as a
    /// line, unless the result is empty.
    private static func append(_ bytes: [UInt8], from: Int, upTo: Int, into lines: inout [String]) {
        var end = upTo
        if end > from, bytes[end - 1] == 0x0D { end -= 1 }
        guard end > from else { return }
        lines.append(String(decoding: bytes[from ..< end], as: UTF8.self))
    }
}
