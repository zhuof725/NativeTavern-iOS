import SwiftUI

/// One character in the list column: avatar, name, last message and time on one
/// row — the same information the reference sidebar shows.
struct SidebarRow: View {
    @ObservedObject var app: AppModel
    let row: CharacterRow
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            EngineImage(client: app.client, path: "characters/\(row.character.avatar)")
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                .overlay { Circle().strokeBorder(Glass.hairline, lineWidth: 0.5) }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.character.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let chat = row.chat {
                        Text(Self.shortTime(chat.lastUpdated))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(Glass.label3)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Glass.label2)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassRow(isSelected: isSelected)
        .contentShape(RoundedRectangle(cornerRadius: Glass.radiusRow, style: .continuous))
    }

    private var subtitle: String {
        if let chat = row.chat {
            let text = chat.lastMessage.isEmpty ? chat.preview : chat.lastMessage
            return ContentFormatter.plain(text)
        }
        return ContentFormatter.plain(row.character.description)
    }

    /// Upstream timestamps are epoch milliseconds (or already formatted text).
    static func shortTime(_ raw: String) -> String {
        guard let value = Double(raw) else { return "" }
        let date = Date(timeIntervalSince1970: value > 1_000_000_000_000 ? value / 1000 : value)
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else if calendar.isDateInYesterday(date) {
            return "昨天"
        } else {
            formatter.dateFormat = "M/d"
        }
        return formatter.string(from: date)
    }
}

/// Text helpers shared by the list and the reading column.
enum ContentFormatter {
    /// Removes markdown emphasis that is noise in a one-line preview.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "_", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}
