// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFiltCLICore
import Testing

/// TTY-aware color: `auto` colors only on a terminal, escapes wrap only the inserted demanglings, machine output (JSON, trees) never colors, and stripping the escapes recovers the plain output exactly.
@Suite("Color behavior")
struct ColorBehaviorTests {
    static let escape = Character("\u{1B}")
    let frame = "0 MyApp 0x104abc123 $s4main3fooyyF + 12\n"

    @Test func autoWithoutTTYEmitsNoEscapes() {
        let run = runCLI(["--color", "auto"], stdinText: frame, tty: false)
        #expect(run.status == CLI.exitSuccess)
        #expect(!run.stdout.contains(Self.escape))
        #expect(run.stdout == "0 MyApp 0x104abc123 main.foo() -> () + 12\n")
    }

    @Test func autoWithTTYColorsTheReplacement() {
        let run = runCLI(["--color", "auto"], stdinText: frame, tty: true)
        #expect(run.stdout == "0 MyApp 0x104abc123 \u{1B}[36mmain.foo() -> ()\u{1B}[0m + 12\n")
    }

    @Test func defaultModeIsAuto() {
        #expect(!runCLI([], stdinText: frame, tty: false).stdout.contains(Self.escape))
        #expect(runCLI([], stdinText: frame, tty: true).stdout.contains(Self.escape))
    }

    @Test func alwaysColorsEvenWhenPiped() {
        let run = runCLI(["--color", "always"], stdinText: frame, tty: false)
        #expect(run.stdout.contains("\u{1B}[36mmain.foo() -> ()\u{1B}[0m"))
    }

    @Test func neverStaysPlainOnTTY() {
        let run = runCLI(["--color", "never"], stdinText: frame, tty: true)
        #expect(!run.stdout.contains(Self.escape))
    }

    @Test func onlyTheReplacementIsWrapped() {
        // Surrounding log text carries no new escapes — input bytes
        // before and after the symbol are untouched.
        let run = runCLI(["--color", "always"], stdinText: frame)
        #expect(run.stdout.hasPrefix("0 MyApp 0x104abc123 \u{1B}[36m"))
        #expect(run.stdout.hasSuffix("\u{1B}[0m + 12\n"))
    }

    @Test func passThroughLinesNeverGainEscapes() {
        let run = runCLI(["--color", "always"], stdinText: "no symbols here\n")
        #expect(run.stdout == "no symbols here\n")
    }

    @Test func coloredOutputMatchesPlainAfterStrippingEscapes() {
        let input = fixtureBytes(cliInputPath("crash-log.txt"))
        let plain = runCLI(["--color", "never"], stdin: input)
        let colored = runCLI(["--color", "always"], stdin: input)
        #expect(stripANSI(colored.stdout) == plain.stdout)
        #expect(colored.stdout != plain.stdout, "the fixture has matches, so escapes must appear")
    }

    @Test func jsonIsNeverColoredEvenWithAlways() {
        let run = runCLI(["--json", "--color", "always"], stdinText: frame, tty: true)
        #expect(!run.stdout.contains(Self.escape))
        #expect(run.stdout.contains("\"mangled\":\"$s4main3fooyyF\""))
    }

    @Test func treesAreNeverColored() {
        let run = runCLI(["--tree", "--color", "always"], stdinText: frame, tty: true)
        #expect(!run.stdout.contains(Self.escape))
        #expect(run.stdout.hasPrefix("Demangling for $s4main3fooyyF\n"))
    }

    @Test func argsModeIsNeverColored() {
        // The whole line is the demangling; there is nothing to set off.
        let run = runCLI(["--color", "always", "$s4main3fooyyF"], tty: true)
        #expect(run.stdout == "main.foo() -> ()\n")
    }

    @Test func resolvedPolicyTruthTable() {
        #expect(ColorMode.auto.resolved(standardOutputIsTTY: true))
        #expect(!ColorMode.auto.resolved(standardOutputIsTTY: false))
        #expect(ColorMode.always.resolved(standardOutputIsTTY: false))
        #expect(ColorMode.always.resolved(standardOutputIsTTY: true))
        #expect(!ColorMode.never.resolved(standardOutputIsTTY: true))
        #expect(!ColorMode.never.resolved(standardOutputIsTTY: false))
    }

    @Test func paletteIsIdentityWhenDisabledAndNeverWrapsEmptyText() {
        let off = Palette(enabled: false)
        #expect(off.demangled("x") == "x")
        let on = Palette(enabled: true)
        #expect(on.demangled("x") == "\u{1B}[36mx\u{1B}[0m")
        #expect(on.demangled("") == "")
    }

    /// Remove ANSI SGR sequences (`ESC [ ... m`).
    func stripANSI(_ text: String) -> String {
        var out = ""
        var inEscape = false
        for character in text {
            if inEscape {
                inEscape = character != "m"
            } else if character == Self.escape {
                inEscape = true
            } else {
                out.append(character)
            }
        }
        return out
    }
}
