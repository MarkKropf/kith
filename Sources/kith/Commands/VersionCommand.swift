import ArgumentParser
import Foundation

struct VersionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print kith version."
    )

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    @OptionGroup var common: CommonOutputOptions

    func run() async throws {
        common.applyStyle()
        if json {
            struct Payload: Encodable {
                let name: String
                let version: String
                let commit: String
                let platform: String
                let builtAt: String
            }
            let p = Payload(
                name: BuildInfo.name,
                version: BuildInfo.version,
                commit: BuildInfo.commit,
                platform: BuildInfo.platform,
                builtAt: BuildInfo.builtAt
            )
            let data = try KithJSON.encoder().encode(p)
            print(String(decoding: data, as: UTF8.self))
        } else {
            print("\(BuildInfo.name) \(BuildInfo.version)")
        }
    }
}
