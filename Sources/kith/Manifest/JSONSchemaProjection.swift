import Foundation

/// Canonical JSON Schema 2020-12 fragments per type. Used both as the
/// `types` dictionary in the kith-native manifest and as the response of
/// `kith tools schema --type X`.
enum JSONSchemaProjection {
    /// Project a single command's parameters as a JSON Schema 2020-12 object.
    static func parametersSchema(for cmd: ManifestCommand) -> [String: Any] {
        var properties: [String: Any] = [:]
        var required: [String] = []
        for arg in cmd.arguments {
            var prop: [String: Any] = [:]
            prop["type"] = arg.type
            if let desc = arg.description { prop["description"] = desc }
            if let any = arg.anyOf {
                prop["oneOf"] = any.map { (entry: [String: AnyCodable]) -> [String: Any] in
                    var out: [String: Any] = [:]
                    for (k, v) in entry { out[k] = v.value }
                    return out
                }
            }
            if let def = arg.default {
                prop["default"] = def.value
            }
            properties[arg.name] = prop
            if arg.required { required.append(arg.name) }
        }
        var schema: [String: Any] = [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "properties": properties,
        ]
        if !required.isEmpty {
            schema["required"] = required
        }
        return schema
    }

    static func contactSchema() -> [String: Any] {
        return [
            "type": "object",
            "required": ["id", "fullName"],
            "properties": [
                "id": ["type": "string"],
                "givenName": ["type": ["string", "null"]],
                "familyName": ["type": ["string", "null"]],
                "fullName": ["type": "string"],
                "nickname": ["type": ["string", "null"]],
                "emails": ["type": "array", "items": labeledEmail()],
                "phones": ["type": "array", "items": labeledPhone()],
                "organization": ["type": ["string", "null"]],
                "jobTitle": ["type": ["string", "null"]],
                "birthday": partialDate(),
                "addresses": ["type": "array", "items": labeledAddress()],
            ],
        ]
    }

    private static func labeledEmail() -> [String: Any] {
        return [
            "type": "object",
            "required": ["value"],
            "properties": [
                "label": ["type": ["string", "null"]],
                "value": ["type": "string"],
            ],
        ]
    }

    private static func labeledPhone() -> [String: Any] {
        return [
            "type": "object",
            "required": ["value", "raw"],
            "properties": [
                "label": ["type": ["string", "null"]],
                "value": ["type": "string", "description": "E.164 when normalization succeeds; raw fallback otherwise."],
                "raw": ["type": "string"],
            ],
        ]
    }

    private static func labeledAddress() -> [String: Any] {
        return [
            "type": "object",
            "properties": [
                "label": ["type": ["string", "null"]],
                "street": ["type": ["string", "null"]],
                "city": ["type": ["string", "null"]],
                "state": ["type": ["string", "null"]],
                "postalCode": ["type": ["string", "null"]],
                "country": ["type": ["string", "null"]],
                "isoCountryCode": ["type": ["string", "null"]],
            ],
        ]
    }

    private static func partialDate() -> [String: Any] {
        return [
            "anyOf": [
                ["type": "null"],
                [
                    "type": "object",
                    "required": ["month", "day"],
                    "properties": [
                        "year": ["type": ["integer", "null"]],
                        "month": ["type": "integer"],
                        "day": ["type": "integer"],
                    ],
                ],
            ],
        ]
    }

    static func contactGroupSchema() -> [String: Any] {
        return [
            "type": "object",
            "required": ["id", "name", "memberCount"],
            "properties": [
                "id": ["type": "string"],
                "name": ["type": "string"],
                "memberCount": ["type": "integer"],
            ],
        ]
    }

    static func chatSchema() -> [String: Any] {
        return [
            "type": "object",
            "required": ["id", "guid", "identifier", "name", "service", "participants", "lastMessageAt"],
            "properties": [
                "id": ["type": "integer"],
                "guid": ["type": "string"],
                "identifier": ["type": "string"],
                "name": ["type": "string"],
                "service": ["type": "string"],
                "participants": ["type": "array", "items": ["type": "string"]],
                "lastMessageAt": ["type": "string", "format": "date-time"],
            ],
        ]
    }

    static func messageSchema() -> [String: Any] {
        return [
            "type": "object",
            "required": ["id", "chatId", "guid", "sender", "isFromMe", "service", "text", "date", "attachmentsCount", "isReaction"],
            "properties": [
                "id": ["type": "integer"],
                "chatId": ["type": "integer"],
                "guid": ["type": "string"],
                "replyToGuid": ["type": ["string", "null"]],
                "threadOriginatorGuid": ["type": ["string", "null"]],
                "destinationCallerId": ["type": ["string", "null"]],
                "sender": ["type": "string"],
                "isFromMe": ["type": "boolean"],
                "service": ["type": "string"],
                "text": ["type": "string"],
                "date": ["type": "string", "format": "date-time"],
                "attachmentsCount": ["type": "integer"],
                "attachments": ["anyOf": [["type": "null"], ["type": "array", "items": attachmentSchema()]]],
                "isReaction": ["type": "boolean"],
                "reactionType": ["type": ["string", "null"]],
                "isReactionAdd": ["type": ["boolean", "null"]],
                "reactedToGuid": ["type": ["string", "null"]],
            ],
        ]
    }

    static func handleSchema() -> [String: Any] {
        return [
            "type": "object",
            "required": ["kind", "value", "raw"],
            "properties": [
                "kind": ["type": "string", "enum": ["phone", "email", "other"]],
                "value": ["type": "string"],
                "raw": ["type": "string"],
            ],
        ]
    }

    static func attachmentSchema() -> [String: Any] {
        return [
            "type": "object",
            "required": ["filename", "transferName", "uti", "mimeType", "totalBytes", "isSticker", "originalPath", "missing"],
            "properties": [
                "filename": ["type": "string"],
                "transferName": ["type": "string"],
                "uti": ["type": "string"],
                "mimeType": ["type": "string"],
                "totalBytes": ["type": "integer"],
                "isSticker": ["type": "boolean"],
                "originalPath": ["type": "string"],
                "missing": ["type": "boolean"],
            ],
        ]
    }

    static func errorSchema() -> [String: Any] {
        return [
            "type": "object",
            "required": ["code", "exit", "message"],
            "properties": [
                "code": ["type": "string"],
                "exit": ["type": "integer"],
                "message": ["type": "string"],
                "hint": ["type": ["string", "null"]],
                "candidates": ["type": ["array", "null"]],
            ],
        ]
    }

    static func doctorReportSchema() -> [String: Any] {
        let permission: [String: Any] = [
            "type": "object",
            "required": ["status"],
            "properties": [
                "status": ["type": "string", "enum": ["granted", "denied", "restricted", "not-determined", "n/a-in-v1"]],
                "hint": ["type": ["string", "null"]],
            ],
        ]
        return [
            "type": "object",
            "required": ["kith", "platform", "permissions", "messagesDb", "contactsStore", "ok"],
            "properties": [
                "kith": [
                    "type": "object",
                    "properties": [
                        "version": ["type": "string"],
                        "commit": ["type": "string"],
                    ],
                ],
                "platform": [
                    "type": "object",
                    "properties": [
                        "macOS": ["type": "string"],
                        "binaryArch": ["type": "string"],
                    ],
                ],
                "permissions": [
                    "type": "object",
                    "properties": [
                        "contacts": permission,
                        "fullDiskAccess": permission,
                        "automationMessages": permission,
                    ],
                ],
                "messagesDb": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string"],
                        "openable": ["type": "boolean"],
                        "schemaFlags": ["type": "object"],
                    ],
                ],
                "contactsStore": [
                    "type": "object",
                    "properties": [
                        "openable": ["type": "boolean"],
                        "totalContacts": ["type": "integer"],
                    ],
                ],
                "ok": ["type": "boolean"],
            ],
        ]
    }
}
