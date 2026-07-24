// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import Foundation
import SwiftFilt
import SwiftFiltCLICore
import Testing

/// The `--json` NDJSON stream: schema-v1 field set and fixed order, filter-mode provenance, args-mode records, and byte-stable goldens.
@Suite("JSON output")
struct JSONOutputTests {
    func object(_ line: some StringProtocol) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    /// The keys of one NDJSON line in emission order (JSONSerialization
    /// loses order, so goldens and this regex-free scan carry it).
    func orderedKeys(_ line: some StringProtocol) -> [String] {
        var keys: [String] = []
        var depth = 0
        var inString = false
        var escaped = false
        var current = ""
        var expectingKey = true
        for character in line {
            if inString {
                if escaped {
                    escaped = false
                    current.append(character)
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                } else {
                    current.append(character)
                }
                continue
            }
            switch character {
            case "\"":
                inString = true
                current = ""
            case "{", "[":
                depth += 1
                expectingKey = depth == 1
            case "}", "]":
                depth -= 1
            case ":" where depth == 1 && expectingKey:
                keys.append(current)
                expectingKey = false
            case "," where depth == 1:
                expectingKey = true
            default:
                break
            }
        }
        return keys
    }

    // MARK: Goldens

    @Test func crashLogJSONMatchesGolden() {
        let run = runCLI(["--json"], stdin: fixtureBytes(cliInputPath("crash-log.txt")))
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stdout == golden("crash-log.ndjson"))
    }

    @Test func crashLogSlimJSONMatchesGolden() {
        let run = runCLI(["--json", "--slim"], stdin: fixtureBytes(cliInputPath("crash-log.txt")))
        #expect(run.stdout == golden("crash-log.slim.ndjson"))
    }

    // MARK: Schema shape

    @Test func everyRecordCarriesTheMandatoryFieldsInSchemaOrder() throws {
        let run = runCLI(["--json"], stdin: fixtureBytes(cliInputPath("crash-log.txt")))
        let lines = run.stdout.split(separator: "\n")
        #expect(lines.count == 6, "six real symbols in the fixture")
        let schemaOrder = [
            "schemaVersion", "mangled", "demangled", "style", "module", "path", "kind",
            "accessor", "thunk", "metadata", "isStatic", "isThunk", "isSpecialized",
            "genericOrigin", "identityKey", "line", "byteOffset",
        ]
        for line in lines {
            let record = try #require(object(line))
            #expect(record["schemaVersion"] as? Int == 1)
            for mandatory in ["mangled", "demangled", "style", "kind", "identityKey", "line", "byteOffset"] {
                #expect(record[mandatory] != nil, "\(mandatory) missing")
            }
            #expect(record["style"] as? String == "full")
            // Emission order is the documented schema order (a subsequence
            // of it — optionals may be absent, never reordered).
            let keys = orderedKeys(line)
            var cursor = 0
            for key in keys {
                let position = try #require(schemaOrder[cursor...].firstIndex(of: key), "unknown or misplaced key \(key)")
                cursor = position + 1
            }
        }
    }

    @Test func provenancePointsAtTheMangledBytes() throws {
        let input = fixtureBytes(cliInputPath("crash-log.txt"))
        let run = runCLI(["--json"], stdin: input)
        // Rebuild each line's bytes and check the mangled name sits at
        // byteOffset — the documented meaning of the provenance pair.
        let inputLines = String(decoding: input, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        for line in run.stdout.split(separator: "\n") {
            let record = try #require(object(line))
            let lineNumber = try #require(record["line"] as? Int)
            let byteOffset = try #require(record["byteOffset"] as? Int)
            let mangled = try #require(record["mangled"] as? String)
            let sourceLine = Array(inputLines[lineNumber - 1].utf8)
            #expect(Array(sourceLine[byteOffset ..< byteOffset + mangled.utf8.count]) == Array(mangled.utf8))
        }
    }

    @Test func lineNumbersAreOneBasedAndCountEveryLine() {
        let run = runCLI(["--json"], stdinText: "$s4main3fooyyF\n\nplain\n$s4main3fooyyF")
        let lines = run.stdout.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(object(lines[0])?["line"] as? Int == 1)
        // The final unterminated line still counts as line 4.
        #expect(object(lines[1])?["line"] as? Int == 4)
        #expect(object(lines[1])?["byteOffset"] as? Int == 0)
    }

    @Test func recordFieldsMatchTheProductAPI() throws {
        // The record is DemangledSymbol, serialized: field for field.
        let run = runCLI(["--json"], stdinText: "x $s4main3fooyyFSi_Tg5 y\n")
        let firstLine = try #require(run.stdout.split(separator: "\n").first)
        let record = try #require(object(firstLine))
        let symbol = try #require(DemangledSymbol("$s4main3fooyyFSi_Tg5"))
        #expect(record["mangled"] as? String == symbol.mangledName)
        #expect(record["demangled"] as? String == symbol.rendered(.full))
        #expect(record["module"] as? String == symbol.module)
        #expect(record["path"] as? [String] == symbol.path)
        #expect(record["kind"] as? String == "function")
        #expect(record["isStatic"] as? Bool == symbol.isStatic)
        #expect(record["isThunk"] as? Bool == symbol.isThunk)
        #expect(record["isSpecialized"] as? Bool == true)
        #expect(record["genericOrigin"] as? String == symbol.genericOrigin)
        #expect(record["identityKey"] as? String == symbol.identityKey.rawValue)
    }

    @Test func kindPayloadsGetTheirOwnFields() throws {
        // accessor / thunk payloads surface as their own keys.
        let getter = try #require(object(runCLI(["--json", "$s10AppIntents0aB8XPCErrorO9errorCodeSivg"]).stdout))
        #expect(getter["kind"] as? String == "accessor")
        #expect(getter["accessor"] as? String == "getter")
        #expect(getter["thunk"] == nil && getter["metadata"] == nil)

        let witness = try #require(object(runCLI(["--json", "_T013call_protocol1CCAA1PA2aDP3fooSiyFTW"]).stdout))
        #expect(witness["kind"] as? String == "protocolWitness")
        #expect(witness["isThunk"] as? Bool == true)

        // Thunk payload: a reabstraction thunk helper (oracle-verified
        // demangling). Its mangling carries only signatures, so no module.
        let thunk = try #require(object(runCLI(["--json", "$sIeg_ytIegr_TR"]).stdout))
        #expect(thunk["kind"] as? String == "thunk")
        #expect(thunk["thunk"] as? String == "reabstraction")
        #expect(thunk["accessor"] == nil && thunk["metadata"] == nil)
        #expect(thunk["module"] == nil)

        // Metadata payload: a type metadata accessor (oracle-verified).
        let metadata = try #require(object(runCLI(["--json", "$s4main3FooVMa"]).stdout))
        #expect(metadata["kind"] as? String == "metadata")
        #expect(metadata["metadata"] as? String == "typeMetadata")
        #expect(metadata["accessor"] == nil && metadata["thunk"] == nil)
        #expect(metadata["module"] as? String == "main")
    }

    @Test func selectedStyleDrivesTheDemangledField() throws {
        let run = runCLI(["--json", "--simplified", "$s4main6ServerC5start4portySi_tF"])
        let record = try #require(object(run.stdout))
        #expect(record["demangled"] as? String == "Server.start(port:)")
        #expect(record["style"] as? String == "simplified")
    }

    // MARK: Args mode

    @Test func argsModeEmitsOneRecordPerDemanglingArgumentWithoutProvenance() throws {
        let run = runCLI(["--json", "$s4main3fooyyF", "notasymbol", "$s4main3fooyyF"])
        let lines = run.stdout.split(separator: "\n")
        // notasymbol emits nothing: the stream is exactly the demangled
        // symbols (documented); duplicates emit per occurrence.
        #expect(lines.count == 2)
        for line in lines {
            let record = try #require(object(line))
            #expect(record["mangled"] as? String == "$s4main3fooyyF")
            #expect(record["line"] == nil && record["byteOffset"] == nil)
        }
        #expect(run.status == CLI.exitSuccess)
    }

    @Test func jsonOutputIsNDJSONOneObjectPerLine() {
        let run = runCLI(["--json"], stdin: fixtureBytes(cliInputPath("crash-log.txt")))
        for line in run.stdout.split(separator: "\n") {
            #expect(object(line) != nil, "every line parses standalone")
        }
        #expect(run.stdout.hasSuffix("\n"), "the last record line is terminated")
    }

    // MARK: Schema stability

    @Test func stringEscapesTheJSONMandatorySet() {
        // The hand-rolled emitter escapes exactly what JSON requires: the
        // two-character forms where JSON names them, \u00XX below 0x20,
        // and raw pass-through for everything else (UTF-8 stays UTF-8).
        #expect(JSONText.string(#"say "hi""#) == #""say \"hi\"""#)
        #expect(JSONText.string(#"a\b"#) == #""a\\b""#)
        #expect(JSONText.string("line\nbreak") == #""line\nbreak""#)
        #expect(JSONText.string("cr\rlf") == #""cr\rlf""#)
        #expect(JSONText.string("tab\tstop") == #""tab\tstop""#)
        #expect(JSONText.string("\u{01}") == #""\u0001""#)
        #expect(JSONText.string("\u{1F}") == #""\u001f""#)
        #expect(JSONText.string("Ünïcödé ✓") == "\"Ünïcödé ✓\"")
        #expect(JSONText.string("") == "\"\"")
    }

    @Test func schemaNamesAreTheCaseNamesVerbatim() {
        // The documented schema vocabulary: every mapper returns the case
        // name verbatim. Payload-less enumerations are listed exhaustively;
        // JSONText's switches are exhaustive by construction, so a grammar
        // addition is a compile error there and a new row here.
        let styles: [(DemangleStyle, String)] = [
            (.full, "full"), (.simplified, "simplified"),
            (.qualified, "qualified"), (.unqualified, "unqualified"),
        ]
        #expect(styles.count == DemangleStyle.allCases.count)
        for (style, name) in styles {
            #expect(JSONText.styleName(style) == name)
        }

        let kinds: [(DemangledSymbol.Kind, String)] = [
            (.function, "function"), (.initializer, "initializer"),
            (.deinitializer, "deinitializer"), (.accessor(.getter), "accessor"),
            (.variable, "variable"), (.subscriptDeclaration, "subscriptDeclaration"),
            (.closure, "closure"), (.variableInitializer, "variableInitializer"),
            (.defaultArgument, "defaultArgument"), (.type, "type"),
            (.enumCase, "enumCase"), (.protocolDeclaration, "protocolDeclaration"),
            (.protocolWitness, "protocolWitness"), (.thunk(.reabstraction), "thunk"),
            (.outlined, "outlined"), (.macro, "macro"),
            (.metadata(.typeMetadata), "metadata"), (.other, "other"),
        ]
        for (kind, name) in kinds {
            #expect(JSONText.kindName(kind) == name)
        }

        let accessors: [(DemangledSymbol.AccessorKind, String)] = [
            (.getter, "getter"), (.setter, "setter"), (.willSet, "willSet"),
            (.didSet, "didSet"), (.read, "read"), (.yieldingBorrow, "yieldingBorrow"),
            (.modify, "modify"), (.yieldingMutate, "yieldingMutate"),
            (.borrow, "borrow"), (.mutate, "mutate"),
            (.unsafeAddressor, "unsafeAddressor"),
            (.unsafeMutableAddressor, "unsafeMutableAddressor"),
            (.owningAddressor, "owningAddressor"),
            (.owningMutableAddressor, "owningMutableAddressor"),
            (.nativeOwningAddressor, "nativeOwningAddressor"),
            (.nativeOwningMutableAddressor, "nativeOwningMutableAddressor"),
            (.nativePinningAddressor, "nativePinningAddressor"),
            (.nativePinningMutableAddressor, "nativePinningMutableAddressor"),
            (.initAccessor, "initAccessor"), (.globalGetter, "globalGetter"),
            (.materializeForSet, "materializeForSet"),
        ]
        #expect(accessors.count == DemangledSymbol.AccessorKind.allCases.count)
        for (accessor, name) in accessors {
            #expect(JSONText.accessorName(accessor) == name)
        }

        let thunks: [(DemangledSymbol.ThunkKind, String)] = [
            (.reabstraction, "reabstraction"), (.curry, "curry"),
            (.dispatch, "dispatch"), (.keyPath, "keyPath"),
            (.partialApply, "partialApply"), (.vtable, "vtable"),
            (.objCAsyncCompletion, "objCAsyncCompletion"),
            (.identity, "identity"), (.autoDiff, "autoDiff"),
        ]
        for (thunk, name) in thunks {
            #expect(JSONText.thunkName(thunk) == name)
        }

        let metadataKinds: [(DemangledSymbol.MetadataKind, String)] = [
            (.typeMetadata, "typeMetadata"), (.typeDescriptor, "typeDescriptor"),
            (.protocolDescriptor, "protocolDescriptor"), (.conformance, "conformance"),
            (.valueWitness, "valueWitness"), (.reflection, "reflection"),
        ]
        for (metadata, name) in metadataKinds {
            #expect(JSONText.metadataName(metadata) == name)
        }
    }
}
