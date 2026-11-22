import SwiftUI
import UIKit

/// Renders one roleplay message the way the tavern does.
///
/// SillyTavern messages are Markdown with two conventions of their own: prose
/// wrapped in `*asterisks*` is narration (shown in italics and slightly dimmed),
/// and `"quoted"` text is speech. The renderer walks the text once and builds an
/// `AttributedString`, so emphasis, code and quotes all survive without a web
/// view — and block-level Markdown (lists, headings, rules) is handled per line.
enum MessageRenderer {
    /// Colours stay in the app's palette: narration is secondary, speech inherits.
    static func render(_ text: String, narration: Color = .secondary) -> AttributedString {
        var result = AttributedString()
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            result.append(renderLine(line, narration: narration))
        }
        return result
    }

    private static func renderLine(_ line: String, narration: Color) -> AttributedString {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Horizontal rule.
        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            var rule = AttributedString("──────────")
            rule.foregroundColor = .secondary.opacity(0.5)
            return rule
        }

        // Headings: keep the words, drop the hashes, make them bold.
        if let match = trimmed.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
            var heading = inline(String(match.output.2), narration: narration)
            heading.font = .system(size: 15.5, weight: .semibold)
            return heading
        }

        // Bullet and numbered lists keep their marker.
        if let match = trimmed.firstMatch(of: /^([-*+]|\d+\.)\s+(.*)$/) {
            let marker = String(match.output.1)
            let bullet = marker == "-" || marker == "*" || marker == "+" ? "•" : marker
            var item = AttributedString("\(bullet) ")
            item.foregroundColor = .secondary
            item.append(inline(String(match.output.2), narration: narration))
            return item
        }

        return inline(line, narration: narration)
    }

    /// Inline Markdown plus the *narration* convention.
    private static func inline(_ text: String, narration: Color) -> AttributedString {
        var output = AttributedString()
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]

            // *narration* — italic and dimmed, quotes inside keep their mark.
            if character == "*" {
                let rest = text[text.index(after: index)...]
                if let close = rest.firstIndex(of: "*") {
                    let inner = String(rest[rest.startIndex..<close])
                    if !inner.isEmpty {
                        var span = AttributedString("*\(inner)*")
                        span.foregroundColor = narration
                        span.font = .system(size: 15.5).italic()
                        output.append(span)
                        index = text.index(after: close)
                        continue
                    }
                }
            }

            // `code`
            if character == "`" {
                let rest = text[text.index(after: index)...]
                if let close = rest.firstIndex(of: "`") {
                    let inner = String(rest[rest.startIndex..<close])
                    var span = AttributedString(inner)
                    span.font = .system(size: 14, design: .monospaced)
                    span.backgroundColor = .secondary.opacity(0.18)
                    output.append(span)
                    index = text.index(after: close)
                    continue
                }
            }

            // **bold**
            if character == "*", text[index...].hasPrefix("**") {
                let after = text.index(index, offsetBy: 2)
                let rest = text[after...]
                if let close = rest.range(of: "**") {
                    let inner = String(rest[rest.startIndex..<close.lowerBound])
                    var span = AttributedString(inner)
                    span.font = .system(size: 15.5, weight: .semibold)
                    output.append(span)
                    index = close.upperBound
                    continue
                }
            }

            // Collect plain run between markers so Markdown emphasis inside it
            // (underscores, links) is still interpreted.
            var plain = String(character)
            var cursor = text.index(after: index)
            while cursor < text.endIndex, !"*`".contains(text[cursor]) {
                plain.append(text[cursor])
                cursor = text.index(after: cursor)
            }
            output.append(markdown(plain, narration: narration))
            index = cursor
        }

        return output
    }

    /// A plain run: system Markdown parsing covers `_emphasis_`, links, etc.
    private static func markdown(_ text: String, narration: Color) -> AttributedString {
        guard text.contains("_") || text.contains("[") else {
            return AttributedString(text)
        }
        if let parsed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return parsed
        }
        return AttributedString(text)
    }
}

/// A message bubble with the tavern's reading layout: narration dimmed, speech
/// plain, and a compact meta line above.
struct MessageBubble: View {
    let message: ChatMessage
    let characterName: String
    let avatar: LocalEngineClient?
    let characterAvatar: String
    var isGrouped = false

    var body: some View {
        VStack(alignment: message.isUser ? .trailing : .leading, spacing: 5) {
            if !isGrouped {
                HStack(spacing: 6) {
                    if !message.isUser, let avatar {
                        EngineImage(client: avatar, path: "characters/\(characterAvatar)")
                            .frame(width: 20, height: 20)
                            .clipShape(Circle())
                    }
                    Text(message.isUser ? "你" : (message.name.isEmpty ? characterName : message.name))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            MessageContent(text: message.text, client: avatar)
                .padding(.horizontal, message.isUser ? 12 : 0)
                .padding(.vertical, message.isUser ? 8 : 0)
                .background {
                    if message.isUser {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.accentColor.opacity(0.16))
                    }
                }
                .frame(maxWidth: message.isUser ? 300 : .infinity, alignment: message.isUser ? .trailing : .leading)
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    }
}
