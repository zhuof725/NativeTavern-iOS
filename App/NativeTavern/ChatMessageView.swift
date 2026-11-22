import SwiftUI
import UIKit

/// One message drawn according to the chosen reading style.
///
/// Every style uses the same content renderer and the same avatar/title line; the
/// difference is the frame around the prose (none, card, bubble, portrait) and
/// the alignment. Narration stays dimmed italics in all of them.
struct ChatMessageView: View {
    let message: ChatMessage
    let characterName: String
    let avatarPath: String
    let client: LocalEngineClient?
    let style: ReadingStyle
    let bodySize: Double
    let showsInfo: Bool
    let isLast: Bool
    let canSwipe: Bool
    let onSwipe: (String) -> Void

    var body: some View {
        Group {
            if message.isUser {
                userMessage
            } else if message.isSystem {
                Text(MessageRenderer.render(message.text, narration: .secondary))
                    .font(.system(size: bodySize - 1))
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                characterMessage
            }
        }
    }

    // MARK: User

    private var userMessage: some View {
        HStack {
            Spacer(minLength: 44)
            VStack(alignment: .trailing, spacing: 4) {
                MessageContent(text: message.text, client: client)
                    .font(.system(size: bodySize))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.18),
                                in: RoundedRectangle(cornerRadius: style == .bubble ? 18 : 14, style: .continuous))
            }
        }
    }

    // MARK: Character

    private var characterMessage: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
            if showsInfo || isLast {
                metaLine
            }
            if message.swipes.count > 1 {
                swipeControl
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if style.showsAvatar, let client {
                EngineImage(client: client, path: avatarPath)
                    .frame(width: 26, height: 26)
                    .clipShape(Circle())
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Text(message.name.isEmpty ? characterName : message.name)
                .font(.system(size: bodySize, weight: .semibold))
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var content: some View {
        MessageContent(text: message.text, client: client)
            .font(.system(size: bodySize))
            .padding(.leading, style.showsAvatar ? 34 : 0)
            .padding(.horizontal, style.showsCard && !style.showsAvatar ? 14 : 0)
            .padding(.vertical, style.showsCard ? 12 : 0)
            .background {
                if style.showsCard {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.secondary.opacity(style == .document ? 0.10 : 0.14))
                }
            }
            .overlay(alignment: .leading) {
                if style == .hush {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.7))
                        .frame(width: 2)
                        .padding(.leading, 2)
                }
            }
            .padding(.leading, style == .hush ? 6 : 0)
    }

    private var metaLine: some View {
        HStack(spacing: 8) {
            if !message.sendDate.isEmpty, let clock = Self.clock(message.sendDate) {
                Text(clock)
            }
            if !message.name.isEmpty {
                Text(message.name)
            }
            Text("\(message.text.count) 字")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.leading, style.showsAvatar ? 34 : 0)
    }

    private var swipeControl: some View {
        HStack(spacing: 10) {
            Button { onSwipe("left") } label: { Image(systemName: "chevron.left") }
                .disabled(!canSwipe)
            Text("\(min(message.swipeId + 1, message.swipes.count))/\(message.swipes.count)")
                .monospacedDigit()
            Button { onSwipe("right") } label: { Image(systemName: "chevron.right") }
                .disabled(!canSwipe)
        }
        .font(.caption2.weight(.semibold))
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12), in: Capsule())
        .padding(.leading, style.showsAvatar ? 34 : 0)
    }

    static func clock(_ raw: String) -> String? {
        guard let value = Double(raw) else { return nil }
        let date = Date(timeIntervalSince1970: value > 1_000_000_000_000 ? value / 1000 : value)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
