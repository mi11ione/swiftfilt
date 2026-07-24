// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import Foundation
import SwiftFilt
import Testing

/// Parity against apple/swift's own demangler test corpus (`apple.tsv`, `mangled → demangled`): SwiftFilt's `.full` must equal apple's shipped demangling, including exotic constructs (SIL impl types, key-path thunks, macros, opaque/existential shapes, witnesses) the host 6.2 oracle never exercises — the breadth net across the node-kind universe.
@Suite("Swift demangler apple/swift corpus parity")
struct SwiftDemanglerAppleManglingTests {
    private struct Row: Sendable {
        let mangled: String
        let demangled: String
        let lineNumber: Int
    }

    private static func loadRows() throws -> [Row] {
        let path = SwiftDemanglerCorpusParity.fixturePath("apple.tsv")
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        var rows: [Row] = []
        for (idx, raw) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if raw.isEmpty { continue }
            let parts = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { continue }
            rows.append(Row(mangled: parts[0], demangled: parts[1], lineNumber: idx + 1))
        }
        return rows
    }

    @Test func everyAppleManglingRendersToExpectedFull() async throws {
        let rows = try Self.loadRows()
        let failures = await onLargeStack { () -> [String] in
            let demangler = SwiftDemangler(); let printer = SwiftDemanglerPrinter()
            var fails: [String] = []
            for row in rows {
                guard let ast = demangler.demangle(symbol: row.mangled) else {
                    fails.append("L\(row.lineNumber) \(row.mangled): demangle nil (expected `\(row.demangled)`)"); continue
                }
                let full = printer.print(ast, style: .full)
                if full != row.demangled {
                    fails.append("L\(row.lineNumber) \(row.mangled):\n    got=`\(full)`\n    exp=`\(row.demangled)`")
                }
            }
            return fails
        }
        let summary = failures.prefix(40).joined(separator: "\n  ")
        #expect(failures.isEmpty, "\(failures.count) apple-corpus failure(s):\n  \(summary)")
    }
}
