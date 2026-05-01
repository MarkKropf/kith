import ArgumentParser
import Foundation

/// Shared output flags that every human-output-emitting command should
/// include. Today: `--color`. Each command does:
///
///   @OptionGroup var common: CommonOutputOptions
///
///   func run() async throws {
///       common.applyStyle()
///       ...
///   }
///
/// `applyStyle()` mutates `AnsiStyle.auto` so downstream renderers (which
/// read the global) honor the resolved mode.
struct CommonOutputOptions: ParsableArguments {
    @Option(name: .long, help: ArgumentHelp(
        "Color output mode. `auto` (default) honors NO_COLOR / CLICOLOR_FORCE / KITH_COLOR env vars and falls back to TTY detection.",
        valueName: "auto|always|never"
    ))
    var color: ColorMode = .auto

    func applyStyle() {
        AnsiStyle.auto = AnsiStyle.resolve(mode: color)
    }
}
