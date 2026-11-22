import SwiftUI
import UIKit

/// Renders a message's content the way the tavern does.
///
/// Block level is handled first — fenced code, images, headings, lists, rules —
/// and each remaining line goes through the inline renderer, which knows the
/// roleplay conventions: `*narration*` is italic and dimmed, `"speech"` stays
/// plain, `**bold**` and `` `code` `` follow Markdown.
struct MessageContent: View {
    let text: String
    let client: LocalEngineClient?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(of: text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let code, let language):
                    CodeBlockView(code: code, language: language)
                case .image(let path, let alt):
                    MessageImage(client: client, path: path, alt: alt)
                case .text(let line):
                    Text(MessageRenderer.render(line, narration: .secondary))
                        .font(.system(size: 15.5))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
            }
        }
    }

    enum Block {
        case code(String, String?)
        case image(String, String?)
        case text(String)
    }

    /// Splits the message into renderable blocks.
    static func blocks(of text: String) -> [Block] {
        var blocks: [Block] = []
        var buffer: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCode = false

        func flushText() {
            guard !buffer.isEmpty else { return }
            // Blank lines separate paragraphs but do not need their own block;
            // the VStack spacing provides the gap.
            let joined = buffer.joined(separator: "\n")
            buffer.removeAll()
            guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            blocks.append(.text(joined))
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeLines.joined(separator: "\n"), codeLanguage))
                    codeLines.removeAll()
                    codeLanguage = nil
                    inCode = false
                } else {
                    flushText()
                    inCode = true
                    let tag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    codeLanguage = tag.isEmpty ? nil : tag
                }
                continue
            }
            if inCode {
                codeLines.append(line)
                continue
            }

            // A whole line that is only an image reference.
            if let image = imageReference(in: trimmed) {
                flushText()
                blocks.append(.image(image.path, image.alt))
                continue
            }

            buffer.append(line)
        }

        if inCode, !codeLines.isEmpty {
            blocks.append(.code(codeLines.joined(separator: "\n"), codeLanguage))
        }
        flushText()
        return blocks.isEmpty ? [.text(text)] : blocks
    }

    /// Recognises `![alt](path)` and a bare image URL.
    static func imageReference(in line: String) -> (path: String, alt: String?)? {
        if line.hasPrefix("!["), let close = line.firstIndex(of: "]") {
            let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<close])
            let after = line[line.index(after: close)...]
            if after.hasPrefix("("), after.hasSuffix(")") {
                let path = String(after.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if !path.isEmpty { return (path, alt.isEmpty ? nil : alt) }
            }
        }
        let lower = line.lowercased()
        let looksLikeImage = ["png", "jpg", "jpeg", "webp", "gif"].contains { lower.hasSuffix(".\($0)") }
        if looksLikeImage, !line.contains(" "), line.contains("/") {
            return (line, nil)
        }
        return nil
    }
}

/// A fenced code block: monospaced, scrollable horizontally.
private struct CodeBlockView: View {
    let code: String
    let language: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// An image referenced by the message.
///
/// Relative paths belong to the tavern's own server (its characters, backgrounds
/// and uploaded files); absolute ones are fetched directly. The engine client is
/// used for the relative case so the request carries the launch token.
private struct MessageImage: View {
    let client: LocalEngineClient?
    let path: String
    let alt: String?

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else if failed {
                Label(alt ?? "图片无法加载", systemImage: "photo.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 180, height: 120)
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
        .task(id: path) { await load() }
    }

    private func load() async {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            if let url = URL(string: path),
               let (data, _) = try? await URLSession.shared.data(from: url),
               let decoded = UIImage(data: data) {
                image = decoded
            } else {
                failed = true
            }
            return
        }
        guard let client else { failed = true; return }
        // Data URLs are how generated images sometimes arrive.
        if path.hasPrefix("data:image"), let comma = path.firstIndex(of: ",") {
            let encoded = String(path[path.index(after: comma)...])
            if let data = Data(base64Encoded: encoded), let decoded = UIImage(data: data) {
                image = decoded
            } else {
                failed = true
            }
            return
        }
        let cleaned = path.hasPrefix("/") ? String(path.dropFirst()) : path
        do {
            let data = try await client.fetch(path: cleaned)
            if let decoded = UIImage(data: data) {
                image = decoded
            } else {
                failed = true
            }
        } catch {
            failed = true
        }
    }
}
