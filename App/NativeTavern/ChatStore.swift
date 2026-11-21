import Foundation
import Combine

/// Chat state for the native UI.
///
/// Every semantic decision here is made by the original SillyTavern core inside
/// the app: the prompt that goes to the model is assembled by upstream's own
/// world-info, macro and prompt-manager code, and this object only carries
/// messages in and the built prompt out.
@MainActor
final class ChatStore: ObservableObject {
    struct Message: Identifiable, Equatable {
        let id = UUID()
        let isUser: Bool
        var text: String
        var isStreaming = false
    }

    @Published private(set) var messages: [Message] = []
    @Published var characterName: String = "Seraphina"
    @Published var characterDescription: String = "A calm ranger with a scarred bow."
    @Published var characterPersonality: String = "Watchful, dry-humoured."
    @Published var scenario: String = "A cold road at dusk."
    @Published var draft: String = ""
    @Published private(set) var status: Status = .idle
    @Published private(set) var lastPrompt: BuiltPrompt?

    enum Status: Equatable {
        case idle
        case building
        case failed(String)
    }

    private let engine: EmbeddedEngine

    init(engine: EmbeddedEngine) {
        self.engine = engine
    }

    var isBusy: Bool { status == .building }

    /// Builds the generation prompt through the original core.
    func buildPrompt() async {
        guard let client = engine.client else {
            status = .failed("本地引擎尚未就绪。")
            return
        }
        status = .building
        do {
            let args: [String: JSONValue] = [
                "character": .object([
                    "name": .string(characterName),
                    "description": .string(characterDescription),
                    "personality": .string(characterPersonality),
                    "scenario": .string(scenario),
                ]),
                "messages": .array(messages.map { message in
                    .object([
                        "name": .string(message.isUser ? "User" : characterName),
                        "is_user": .bool(message.isUser),
                        "mes": .string(message.text),
                    ])
                }),
                "maxContext": .number(8192),
            ]
            lastPrompt = try await client.call("prompt.build", args: args, as: BuiltPrompt.self)
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Sends a message and rebuilds the prompt with the original core.
    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        draft = ""
        messages.append(Message(isUser: true, text: text))
        await buildPrompt()
    }

    func appendReply(_ text: String) {
        messages.append(Message(isUser: false, text: text))
    }
}
