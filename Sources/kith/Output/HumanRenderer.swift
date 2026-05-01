import ContactsCore
import Foundation
import MessagesCore

enum HumanRenderer {
    static func render(contact c: Contact, style: AnsiStyle = .auto) -> String {
        var lines: [String] = []
        lines.append("\(style.bold(c.fullName))  \(style.dim("[\(c.id)]"))")
        if let nick = c.nickname { lines.append("  \(style.dim("nickname:")) \(nick)") }
        if let org = c.organization {
            var orgLine = "  \(style.dim("org:")) \(org)"
            if let job = c.jobTitle { orgLine += " — \(job)" }
            lines.append(orgLine)
        } else if let job = c.jobTitle {
            lines.append("  \(style.dim("title:")) \(job)")
        }
        for p in c.phones {
            let label = p.label.map { "[\($0)] " } ?? ""
            lines.append("  \(style.dim("phone \(label)"))\(p.value)")
        }
        for e in c.emails {
            let label = e.label.map { "[\($0)] " } ?? ""
            lines.append("  \(style.dim("email \(label)"))\(e.value)")
        }
        if let bday = c.birthday {
            let y = bday.year.map(String.init) ?? "----"
            lines.append("  \(style.dim("birthday:")) \(String(format: "%@-%02d-%02d", y, bday.month, bday.day))")
        }
        for a in c.addresses {
            let label = a.label.map { "[\($0)] " } ?? ""
            let parts = [a.street, a.city, a.state, a.postalCode, a.country].compactMap { $0 }
            lines.append("  \(style.dim("addr \(label)"))\(parts.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    static func render(group g: ContactGroup, style: AnsiStyle = .auto) -> String {
        return "\(style.bold(g.name))  \(style.dim("(\(g.memberCount))"))  \(style.dim("[\(g.id)]"))"
    }

    static func render(chat c: KithChat, style: AnsiStyle = .auto) -> String {
        let stamp = KithDateFormatter.string(from: c.lastMessageAt)
        return "\(style.bold("chat-id:\(c.id)"))  \(style.bold(c.name))  \(style.dim("[\(c.service)]"))  \(style.dim("last:")) \(style.dim(stamp))"
    }

    static func render(message m: KithMessage, style: AnsiStyle = .auto) -> String {
        let stamp = style.dim(KithDateFormatter.string(from: m.date))
        let whoRaw = m.isFromMe ? "me" : (m.sender.isEmpty ? "?" : m.sender)
        let who = m.isFromMe ? style.cyan(style.bold(whoRaw)) : style.bold(whoRaw)
        let prefix = "\(stamp)  \(who):"
        if m.isReaction, let rt = m.reactionType {
            let action = (m.isReactionAdd ?? true) ? "+" : "-"
            let colored = colorizeReaction(rt, action: action, style: style)
            return "\(prefix) \(colored) \(m.text)"
        }
        return "\(prefix) \(m.text)"
    }

    private static func colorizeReaction(_ rt: String, action: String, style: AnsiStyle) -> String {
        let token = "[\(action)\(rt)]"
        switch rt {
        case "love":     return style.red(token)
        case "like":     return style.green(token)
        case "dislike":  return style.yellow(token)
        case "laugh":    return style.yellow(token)
        case "emphasis": return style.magenta(token)
        case "question": return style.blue(token)
        default:         return style.cyan(token)
        }
    }
}
