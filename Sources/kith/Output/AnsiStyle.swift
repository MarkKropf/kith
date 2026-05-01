import ArgumentParser
import Foundation

/// User-selectable color mode for the `--color` flag.
public enum ColorMode: String, Sendable, ExpressibleByArgument, CaseIterable {
    case auto, always, never
}

/// ANSI styling for human-mode output. Resolution order:
///
///   1. `--color {always,never,auto}` flag (auto falls through to env)
///   2. `KITH_COLOR=always|never` env
///   3. `NO_COLOR` (any value) env  → disable. (https://no-color.org/)
///   4. `CLICOLOR_FORCE=1` env       → enable.
///   5. fallback: enabled iff `stdout` is a TTY.
///
/// `--jsonl` and other machine-mode emitters bypass this entirely; styling
/// is only applied to human renders. The resolved AnsiStyle exposes a
/// `Source` so `kith doctor --json` can advertise which signal won.
public struct AnsiStyle: Sendable {
    public let useColor: Bool
    public let source: Source

    public enum Source: String, Sendable, Codable {
        case flag                       // --color {always,never}
        case kithColor      = "kith-color"
        case noColor        = "no-color"
        case clicolorForce  = "clicolor-force"
        case isatty                     // stdout is a TTY
        case piped                      // stdout is not a TTY
    }

    public init(useColor: Bool, source: Source) {
        self.useColor = useColor
        self.source = source
    }

    /// Mutable global; set once at command start so individual renderers can
    /// just read `AnsiStyle.auto` without threading the value through every
    /// call site.
    nonisolated(unsafe) public static var auto: AnsiStyle = .detect()

    /// Resolve the effective style given an optional CLI override + env.
    public static func resolve(mode: ColorMode? = nil, env: [String: String] = ProcessInfo.processInfo.environment) -> AnsiStyle {
        if let mode {
            switch mode {
            case .always: return AnsiStyle(useColor: true, source: .flag)
            case .never:  return AnsiStyle(useColor: false, source: .flag)
            case .auto:   break  // fall through to env detection
            }
        }
        return detect(env: env)
    }

    public static func detect(env: [String: String] = ProcessInfo.processInfo.environment) -> AnsiStyle {
        if let v = env["KITH_COLOR"]?.lowercased() {
            switch v {
            case "always": return AnsiStyle(useColor: true, source: .kithColor)
            case "never":  return AnsiStyle(useColor: false, source: .kithColor)
            default: break
            }
        }
        if env["NO_COLOR"] != nil { return AnsiStyle(useColor: false, source: .noColor) }
        if env["CLICOLOR_FORCE"] == "1" { return AnsiStyle(useColor: true, source: .clicolorForce) }
        let tty = isatty(fileno(stdout)) != 0
        return AnsiStyle(useColor: tty, source: tty ? .isatty : .piped)
    }

    public func bold(_ s: String) -> String      { wrap(s, "\u{1B}[1m") }
    public func dim(_ s: String) -> String       { wrap(s, "\u{1B}[2m") }
    public func red(_ s: String) -> String       { wrap(s, "\u{1B}[31m") }
    public func green(_ s: String) -> String     { wrap(s, "\u{1B}[32m") }
    public func yellow(_ s: String) -> String    { wrap(s, "\u{1B}[33m") }
    public func blue(_ s: String) -> String      { wrap(s, "\u{1B}[34m") }
    public func magenta(_ s: String) -> String   { wrap(s, "\u{1B}[35m") }
    public func cyan(_ s: String) -> String      { wrap(s, "\u{1B}[36m") }

    public func boldRed(_ s: String) -> String   { wrap(s, "\u{1B}[1;31m") }
    public func boldGreen(_ s: String) -> String { wrap(s, "\u{1B}[1;32m") }

    private func wrap(_ s: String, _ code: String) -> String {
        guard useColor else { return s }
        return "\(code)\(s)\u{1B}[0m"
    }
}
