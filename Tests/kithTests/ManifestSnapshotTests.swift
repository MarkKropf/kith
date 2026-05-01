import Foundation
import Testing
@testable import kith

@Suite("Manifest projections — sanity")
struct ManifestSnapshotTests {
    @Test("kith-native manifest emits all 8 commands")
    func nativeContainsAllCommands() throws {
        let doc = ManifestEntries.document()
        let names = Set(doc.commands.map(\.name))
        #expect(names.contains("find"))
        #expect(names.contains("get"))
        #expect(names.contains("groups list"))
        #expect(names.contains("groups members"))
        #expect(names.contains("chats"))
        #expect(names.contains("history"))
        #expect(names.contains("doctor"))
        #expect(names.contains("version"))
    }

    @Test("OpenAI projection uses kith_ prefix and function shape")
    func openaiShape() throws {
        let tools = OpenAIProjection.tools()
        #expect(!tools.isEmpty)
        for tool in tools {
            #expect(tool["type"] as? String == "function")
            let function = tool["function"] as? [String: Any]
            #expect(function != nil)
            let name = function?["name"] as? String ?? ""
            #expect(name.hasPrefix("kith_"))
        }
    }

    @Test("Anthropic projection uses input_schema")
    func anthropicShape() throws {
        let tools = AnthropicProjection.tools()
        #expect(!tools.isEmpty)
        for tool in tools {
            #expect(tool["input_schema"] != nil)
            #expect(tool["name"] is String)
        }
    }

    @Test("history command requires --with")
    func historyWithRequired() {
        let doc = ManifestEntries.document()
        let history = doc.commands.first { $0.name == "history" }
        let withArg = history?.arguments.first { $0.name == "with" }
        #expect(withArg?.required == true)
    }

    @Test("Contact JSON Schema includes the partial birthday shape")
    func contactSchemaHasPartialBirthday() {
        let schema = JSONSchemaProjection.contactSchema()
        let props = schema["properties"] as? [String: Any]
        let birthday = props?["birthday"] as? [String: Any]
        #expect(birthday?["anyOf"] != nil)
    }
}
