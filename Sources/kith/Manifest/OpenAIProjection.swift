import Foundation

/// Project the kith manifest as an OpenAI tool function array. The
/// multi-form `--with` arg becomes a single string with a rich description
/// (OpenAI tool schema doesn't widely support `oneOf` at the leaf).
enum OpenAIProjection {
    static func tools() -> [[String: Any]] {
        let doc = ManifestEntries.document()
        return doc.commands.map { cmd in
            return [
                "type": "function",
                "function": [
                    "name": apiName(cmd.name),
                    "description": [cmd.summary, cmd.description ?? ""].filter { !$0.isEmpty }.joined(separator: " "),
                    "parameters": flattenedParameters(for: cmd),
                ],
            ]
        }
    }

    private static func apiName(_ name: String) -> String {
        return "kith_" + name.replacingOccurrences(of: " ", with: "_")
    }

    private static func flattenedParameters(for cmd: ManifestCommand) -> [String: Any] {
        var properties: [String: Any] = [:]
        var required: [String] = []
        for arg in cmd.arguments {
            var prop: [String: Any] = ["type": arg.type]
            if let desc = arg.description {
                prop["description"] = desc
            }
            if let def = arg.default {
                prop["default"] = def.value
            }
            // Collapse oneOf to a single string with description hint.
            properties[arg.name] = prop
            if arg.required { required.append(arg.name) }
        }
        var out: [String: Any] = [
            "type": "object",
            "properties": properties,
        ]
        if !required.isEmpty { out["required"] = required }
        return out
    }
}
