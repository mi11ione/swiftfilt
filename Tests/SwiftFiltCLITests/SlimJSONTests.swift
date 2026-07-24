// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import Foundation
import SwiftFiltCLICore
import Testing

/// The `--slim` JSON projection: drops exactly the documented zero-signal fields (`schemaVersion`, `style`, empty `demangled`/`path`, false booleans), keeps every signal-bearing field byte-equal to the full record, leaves default `--json` untouched, and is a clean usage error without `--json`.
@Suite("Slim JSON projection")
struct SlimJSONTests {
    func object(_ line: some StringProtocol) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    /// Order-independent equality for two parsed JSON values: scalars and
    /// arrays compare by value, objects compare key by key.
    func sameJSON(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case let (a as [String: Any], b as [String: Any]):
            a.count == b.count && a.allSatisfy { sameJSON($0.value, b[$0.key]) }
        case let (a as [Any], b as [Any]):
            a.count == b.count && zip(a, b).allSatisfy { sameJSON($0, $1) }
        default:
            "\(a ?? "·")" == "\(b ?? "·")"
        }
    }

    /// Whether a full-record key slim dropped was provably zero-signal:
    /// a constant, an empty value, or a false boolean.
    func droppable(_ key: String, _ value: Any) -> Bool {
        ["schemaVersion", "style"].contains(key)
            || (key == "demangled" && (value as? String)?.isEmpty == true)
            || (key == "path" && (value as? [Any])?.isEmpty == true)
            || (["isStatic", "isThunk", "isSpecialized"].contains(key) && value as? Bool == false)
    }

    // MARK: Goldens

    @Test func slimStreamMatchesGolden() {
        let run = runCLI(["--json", "--slim"], stdin: fixtureBytes(cliInputPath("crash-log.txt")))
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stdout == golden("crash-log.slim.ndjson"))
    }

    // MARK: Faithful subset

    @Test func slimIsAFaithfulSubsetOfDefault() throws {
        // Every slim key equals the full record's value; every dropped
        // key is provably zero-signal — over the whole fixture stream,
        // order-independent.
        let input = fixtureBytes(cliInputPath("crash-log.txt"))
        let full = runCLI(["--json"], stdin: input).stdout.split(separator: "\n")
        let slim = runCLI(["--json", "--slim"], stdin: input).stdout.split(separator: "\n")
        #expect(full.count == slim.count)
        for (fullLine, slimLine) in zip(full, slim) {
            let fullRecord = try #require(object(fullLine))
            let slimRecord = try #require(object(slimLine))
            for (key, value) in slimRecord {
                #expect(sameJSON(fullRecord[key], value), "slim \(key) diverges from the full record")
            }
            for (key, value) in fullRecord where slimRecord[key] == nil {
                #expect(droppable(key, value), "full key \(key) dropped by slim is signal-bearing")
            }
        }
    }

    @Test func slimArgsRecordsAreFaithfulSubsetsToo() throws {
        // The args-mode path (no provenance) through the same law, with a
        // symbol set that exercises every optional: a specialization
        // (genericOrigin), a static entity, a witness, a getter, and a
        // degenerate no-path symbol.
        let symbols = [
            "$s4main3fooyyFSi_Tg5",
            "$s7Testing4JSONO6decode_4fromxxm_SWtKSeRzlFZxyKXEfU_",
            "_T013call_protocol1CCAA1PA2aDP3fooSiyFTW",
            "$s10AppIntents0aB8XPCErrorO9errorCodeSivg",
            "_T03abc6testitySiFTm",
        ]
        let full = runCLI(["--json"] + symbols).stdout.split(separator: "\n")
        let slim = runCLI(["--json", "--slim"] + symbols).stdout.split(separator: "\n")
        #expect(full.count == symbols.count && slim.count == symbols.count)
        for (fullLine, slimLine) in zip(full, slim) {
            let fullRecord = try #require(object(fullLine))
            let slimRecord = try #require(object(slimLine))
            for (key, value) in slimRecord {
                #expect(sameJSON(fullRecord[key], value), "slim \(key) diverges")
            }
            for (key, value) in fullRecord where slimRecord[key] == nil {
                #expect(droppable(key, value), "dropped \(key) is signal-bearing")
            }
        }
    }

    // MARK: Field omission

    @Test func slimDropsConstantsAlways() throws {
        let run = runCLI(["--json", "--slim"], stdin: fixtureBytes(cliInputPath("crash-log.txt")))
        for line in run.stdout.split(separator: "\n") {
            let record = try #require(object(line))
            #expect(record["schemaVersion"] == nil)
            #expect(record["style"] == nil)
        }
    }

    @Test func slimBooleansAppearOnlyWhenTrue() throws {
        let run = runCLI(["--json", "--slim"], stdin: fixtureBytes(cliInputPath("crash-log.txt")))
        for line in run.stdout.split(separator: "\n") {
            let record = try #require(object(line))
            for key in ["isStatic", "isThunk", "isSpecialized"] {
                if let value = record[key] {
                    #expect(value as? Bool == true, "\(key) false must be omitted")
                }
            }
        }
        // The fixture carries both witnesses (isThunk) and a
        // specialization (isSpecialized), so the projection is exercised
        // in both directions.
        #expect(run.stdout.contains("\"isThunk\":true"))
        #expect(run.stdout.contains("\"isSpecialized\":true"))
    }

    @Test func slimKeepsProvenanceAndIdentity() throws {
        let run = runCLI(["--json", "--slim"], stdin: fixtureBytes(cliInputPath("crash-log.txt")))
        for line in run.stdout.split(separator: "\n") {
            let record = try #require(object(line))
            #expect(record["mangled"] is String)
            #expect(record["kind"] is String)
            #expect(record["identityKey"] is String)
            #expect(record["line"] is Int)
            #expect(record["byteOffset"] is Int)
        }
    }

    @Test func defaultJSONIsUnchangedByTheSlimFeature() {
        // The opt-in projection must not perturb the default stream.
        let run = runCLI(["--json"], stdin: fixtureBytes(cliInputPath("crash-log.txt")))
        #expect(run.stdout == golden("crash-log.ndjson"))
    }

    @Test func slimIsSmallerThanDefault() {
        let input = fixtureBytes(cliInputPath("crash-log.txt"))
        let full = runCLI(["--json"], stdin: input).stdout
        let slim = runCLI(["--json", "--slim"], stdin: input).stdout
        #expect(slim.utf8.count < full.utf8.count)
    }
}
