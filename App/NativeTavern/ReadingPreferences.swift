import SwiftUI
import Combine

/// The reading preferences the appearance screen edits, shared with the chat
/// screen. Loaded once at launch and updated in place, so changing the style in
/// settings is visible immediately in a conversation.
@MainActor
final class ReadingPreferences: ObservableObject {
    static let shared = ReadingPreferences()

    @Published var style: ReadingStyle = .reading
    @Published var accent: AccentChoice = .blue
    @Published var bodySize: Double = 16
    @Published var lineWidth: Double = 720
    /// `hover` · `always` · `never`
    @Published var messageInfo: String = "hover"
    @Published var reducedMotion = false
    @Published var blur = true
    @Published var background: String = ""

    private init() {}

    func update(style: ReadingStyle, accent: AccentChoice, bodySize: Double, lineWidth: Double,
                messageInfo: String, reducedMotion: Bool, blur: Bool, background: String) {
        self.style = style
        self.accent = accent
        self.bodySize = bodySize
        self.lineWidth = lineWidth
        self.messageInfo = messageInfo
        self.reducedMotion = reducedMotion
        self.blur = blur
        self.background = background
    }

    /// Applies a snapshot fetched from the engine.
    func load(from client: LocalEngineClient) async {
        struct Look: Decodable {
            let fontScale: Double
            let blur: Bool
            let reducedMotion: Bool
            let background: String
            let style: String
            let accent: String
            let bodySize: Double
            let lineWidth: Double
            let messageInfo: String
        }
        guard let look = try? await client.call("appearance.get", as: Look.self) else { return }
        update(style: ReadingStyle(rawValue: look.style) ?? .reading,
               accent: AccentChoice(rawValue: look.accent) ?? .blue,
               bodySize: look.bodySize,
               lineWidth: look.lineWidth,
               messageInfo: look.messageInfo,
               reducedMotion: look.reducedMotion,
               blur: look.blur,
               background: look.background)
    }

    var animation: Animation? { reducedMotion ? nil : .easeOut(duration: 0.18) }
    var bodyFont: Font { .system(size: bodySize) }
    var maxLineWidth: CGFloat { CGFloat(lineWidth) }
}
