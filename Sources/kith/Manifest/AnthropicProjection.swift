import Foundation

/// Project the kith manifest as Anthropic tool definitions. Anthropic's
/// `input_schema` accepts JSON Schema, so `oneOf` survives.
enum AnthropicProjection {
    static func tools() -> [[String: Any]] {
        let doc = ManifestEntries.document()
        return doc.commands.map { cmd in
            return [
                "name": apiName(cmd.name),
                "description": [cmd.summary, cmd.description ?? ""].filter { !$0.isEmpty }.joined(separator: " "),
                "input_schema": JSONSchemaProjection.parametersSchema(for: cmd),
            ]
        }
    }

    private static func apiName(_ name: String) -> String {
        return "kith_" + name.replacingOccurrences(of: " ", with: "_")
    }
}
