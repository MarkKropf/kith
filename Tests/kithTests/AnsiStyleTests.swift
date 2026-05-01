import Foundation
import Testing
@testable import kith

@Suite("AnsiStyle — env-based detection + escape codes")
struct AnsiStyleTests {
    @Test("KITH_COLOR=always forces color regardless of TTY")
    func kithColorAlwaysForces() {
        let s = AnsiStyle.detect(env: ["KITH_COLOR": "always"])
        #expect(s.useColor == true)
    }

    @Test("KITH_COLOR=never disables color regardless of TTY")
    func kithColorNeverDisables() {
        let s = AnsiStyle.detect(env: ["KITH_COLOR": "never"])
        #expect(s.useColor == false)
    }

    @Test("NO_COLOR (any value) disables color")
    func noColorRespected() {
        #expect(AnsiStyle.detect(env: ["NO_COLOR": "1"]).useColor == false)
        #expect(AnsiStyle.detect(env: ["NO_COLOR": ""]).useColor == false)
    }

    @Test("CLICOLOR_FORCE=1 enables color")
    func clicolorForce() {
        let s = AnsiStyle.detect(env: ["CLICOLOR_FORCE": "1"])
        #expect(s.useColor == true)
    }

    @Test("KITH_COLOR overrides NO_COLOR")
    func kithColorBeatsNoColor() {
        let s = AnsiStyle.detect(env: ["KITH_COLOR": "always", "NO_COLOR": "1"])
        #expect(s.useColor == true)
    }

    @Test("when useColor is true, wrap emits ANSI codes")
    func wrapsWhenEnabled() {
        let s = AnsiStyle(useColor: true, source: .flag)
        #expect(s.bold("hi") == "\u{1B}[1mhi\u{1B}[0m")
        #expect(s.dim("x") == "\u{1B}[2mx\u{1B}[0m")
        #expect(s.red("e") == "\u{1B}[31me\u{1B}[0m")
        #expect(s.green("g") == "\u{1B}[32mg\u{1B}[0m")
        #expect(s.yellow("y") == "\u{1B}[33my\u{1B}[0m")
        #expect(s.boldRed("E") == "\u{1B}[1;31mE\u{1B}[0m")
        #expect(s.boldGreen("G") == "\u{1B}[1;32mG\u{1B}[0m")
    }

    @Test("when useColor is false, wrap is identity")
    func passthroughWhenDisabled() {
        let s = AnsiStyle(useColor: false, source: .flag)
        #expect(s.bold("hi") == "hi")
        #expect(s.dim("x") == "x")
        #expect(s.red("e") == "e")
        #expect(s.boldRed("E") == "E")
    }

    @Test("resolve(mode:) — flag overrides env")
    func flagOverridesEnv() {
        let env = ["NO_COLOR": "1"]
        #expect(AnsiStyle.resolve(mode: .always, env: env).useColor == true)
        #expect(AnsiStyle.resolve(mode: .always, env: env).source == .flag)
        #expect(AnsiStyle.resolve(mode: .never, env: env).useColor == false)
        #expect(AnsiStyle.resolve(mode: .never, env: env).source == .flag)
        // .auto should fall through to env detection.
        #expect(AnsiStyle.resolve(mode: .auto, env: env).source == .noColor)
    }

    @Test("source records which signal won")
    func sourceTracking() {
        #expect(AnsiStyle.detect(env: ["KITH_COLOR": "always"]).source == .kithColor)
        #expect(AnsiStyle.detect(env: ["NO_COLOR": ""]).source == .noColor)
        #expect(AnsiStyle.detect(env: ["CLICOLOR_FORCE": "1"]).source == .clicolorForce)
        // The fallback is either .isatty or .piped depending on the test
        // runner's TTY state; both are valid.
        let fallback = AnsiStyle.detect(env: [:]).source
        #expect(fallback == .isatty || fallback == .piped)
    }
}
