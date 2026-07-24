// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import Foundation
import SwiftFiltCLICore
import Testing

/// The census NDJSON contract: kind-discriminated objects, documented field order, weight-honest byte fields, every line valid JSON — and the `--help` jq CI-gate example actually runs against the real fixture through the real jq.
@Suite("Census JSON contract")
struct CensusJSONContractTests {
    private func censusJSON(_ fixture: String, flags: [String] = []) -> String {
        runCLI(["census", "--json"] + flags, stdin: fixtureBytes(fixture)).stdout
    }

    @Test func everyLineIsValidJSONAndKindDiscriminated() throws {
        let output = censusJSON(censusFixturePath("LinkMap.txt"))
        let lines = output.split(separator: "\n")
        #expect(lines.count > 10)
        for (index, line) in lines.enumerated() {
            let object = try #require(
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                "line \(index + 1) is not a JSON object",
            )
            let kind = try #require(object["kind"] as? String)
            #expect(kind == (index == 0 ? "census" : "censusRow"))
            #expect(object["schemaVersion"] as? Int == 1)
        }
    }

    @Test func summaryLeadsWithTheDocumentedFieldOrder() {
        let summary = censusJSON(censusFixturePath("LinkMap.txt")).split(separator: "\n")[0]
        #expect(summary.hasPrefix(
            "{\"schemaVersion\":1,\"kind\":\"census\",\"format\":\"linkmap\",\"weight\":\"bytes\",\"detection\":",
        ))
        // The linkmap-only fields are present, in order, after detection.
        #expect(summary.contains("\"path\":\"build/census-fixture\",\"arch\":\"arm64\",\"objectFiles\":"))
        #expect(summary.contains("\"deadStripped\":"))
        #expect(summary.contains("\"unknownOrdinalRows\":0"))
    }

    @Test func rowObjectsCarryTableNameCountBytes() {
        let output = censusJSON(censusFixturePath("LinkMap.txt"))
        #expect(output.contains("{\"schemaVersion\":1,\"kind\":\"censusRow\",\"table\":\"kinds\",\"name\":\"function\",\"count\":"))
        for table in ["kinds", "modules", "specializations", "duplicates"] {
            #expect(output.contains("\"table\":\"\(table)\""), "\(table) table missing")
        }
    }

    @Test func tablesAppearInDocumentedOrder() {
        let output = censusJSON(censusFixturePath("LinkMap.txt"))
        let tables = output.split(separator: "\n").dropFirst().map { line in
            let marker = "\"table\":\""
            let start = line.range(of: marker)!.upperBound
            return String(line[start...].prefix { $0 != "\"" })
        }
        // Grouped, never interleaved, in report order.
        let collapsed = tables.reduce(into: [String]()) { result, table in
            if result.last != table { result.append(table) }
        }
        #expect(collapsed == ["kinds", "modules", "specializations", "duplicates"])
    }

    @Test func countWeightedInputsCarryNoByteFields() {
        let output = censusJSON(censusFixturePath("nm.txt"))
        #expect(output.contains("\"weight\":\"count\""))
        #expect(!output.contains("Bytes\":"))
        #expect(!output.contains("\"bytes\":"))
        #expect(output.contains("\"undefinedRows\":"))
        #expect(!output.contains("\"rowsWithoutSize\":"), "meaningless without a size column")
    }

    @Test func sizedNmCarriesItsHonestyCounters() {
        let output = censusJSON(censusFixturePath("nm-sized.txt"))
        #expect(output.contains("\"weight\":\"bytes\""))
        #expect(output.contains("\"undefinedRows\":4"))
        #expect(output.contains("\"rowsWithoutSize\":4"))
    }

    @Test func bareSummaryOmitsStructuredFormatFields() {
        let output = censusJSON(cliInputPath("crash-log.txt"))
        let summary = String(output.split(separator: "\n")[0])
        #expect(summary.contains("\"format\":\"bare\""))
        for absent in ["structureLines", "unparseableLines", "nonSwift", "malformed",
                       "contentAtoms", "deadStripped", "undefinedRows", "path", "arch"]
        {
            #expect(!summary.contains("\"\(absent)\""), "\(absent) has no meaning for bare text")
        }
        #expect(summary.contains("\"machinery\":"))
    }

    @Test func duplicatesTableOnlyCarriesRealDuplicates() throws {
        let output = censusJSON(censusFixturePath("LinkMap.txt"))
        var duplicateRows = 0
        for line in output.split(separator: "\n") where line.contains("\"table\":\"duplicates\"") {
            duplicateRows += 1
            let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let count = try #require(object["count"] as? Int)
            #expect(count > 1)
        }
        #expect(duplicateRows > 0)
    }

    @Test func theHelpJqGateExampleActuallyRuns() throws {
        // Extract the exact jq program the help text advertises and run
        // it — the example is part of the product surface, so it must
        // work verbatim. (jq ships with macOS 15+ and every CI image.)
        let helpLine = try #require(
            CLI.helpText.split(separator: "\n").first { $0.contains("| jq -es") },
        )
        let quoted = try #require(helpLine.range(of: "jq -es '"))
        let program = String(helpLine[quoted.upperBound...].dropLast())
        #expect(helpLine.hasSuffix("'"), "the help example must be a single-quoted jq program")

        let census = censusJSON(censusFixturePath("LinkMap.txt"))
        let underBudget = try runJq(["-es", program], stdin: census)
        #expect(underBudget.status == 0, "the advertised gate must pass the fixture (thunk bytes are tiny)")
        #expect(underBudget.stdout == "true\n")

        // The same gate with a 1-byte budget must fail the build: that
        // is what makes it a gate.
        let tightProgram = program.replacingOccurrences(of: "262144", with: "1")
        #expect(tightProgram != program, "the example must carry the documented budget")
        let overBudget = try runJq(["-es", tightProgram], stdin: census)
        #expect(overBudget.status == 1)
        #expect(overBudget.stdout == "false\n")
    }

    /// Run the system jq. A missing jq fails the test loudly — the help
    /// example is part of the contract and CI must actually prove it.
    private func runJq(_ arguments: [String], stdin: String) throws -> (status: Int32, stdout: String) {
        let (status, out) = try runTool("/usr/bin/env", ["jq"] + arguments, stdin: Array(stdin.utf8))
        return (status, String(decoding: out, as: UTF8.self))
    }
}
