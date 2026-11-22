import Foundation
import Combine

/// Chat state for the native UI.
///
/// Every semantic decision is made by the original SillyTavern core inside the
/// app: world info, macros and prompt assembly are its own code, and the reply
/// on screen is what its generation path returned. This object carries messages
/// in and out.
@MainActor
final class ChatStore: ObservableObject {
    struct Message: Identifiable, Equatable {
        let id = UUID()
        let isUser: Bool
        var text: String
    }

    @Published private(set) var messages: [Message] = []
    @Published var characterName: String = "Seraphina"
    @Published var draft: String = ""
    @Published private(set) var status: Status = .idle
    @Published private(set) var lastPrompt: BuiltPrompt?
    @Published private(set) var worldInfo: BuiltPrompt.WorldInfoSlice?

    enum Status: Equatable {
        case idle
        case working(String)
        case failed(String)
    }

    private let engine: EmbeddedEngine

    init(engine: EmbeddedEngine) {
        self.engine = engine
    }

    var isBusy: Bool {
        if case .working = status { return true }
        return false
    }

    /// Loads the chat into the core and builds the prompt it would send.
    func refresh() async {
        guard let client = engine.client else {
            status = .failed("本地引擎尚未就绪。")
            return
        }
        status = .working("正在组装提示词…")
        do {
            try await syncChat(client)
            lastPrompt = try await client.call(
                "prompt.build",
                args: ["maxContext": .number(8192)],
                as: BuiltPrompt.self
            )
            worldInfo = lastPrompt?.worldInfo
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Sends the draft and asks the original core for a reply.
    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        draft = ""
        messages.append(Message(isUser: true, text: text))

        guard let client = engine.client else {
            status = .failed("本地引擎尚未就绪。")
            return
        }
        status = .working("模型生成中…")
        do {
            try await syncChat(client)
            let reply: GenerationReply = try await client.call(
                "generate.reply",
                args: [:],
                as: GenerationReply.self
            )
            for message in reply.messages where !message.content.isEmpty {
                messages.append(Message(isUser: message.role == "user", text: message.content))
            }
            lastPrompt = nil
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// The chat lives in the core; the UI's messages are pushed into it before
    /// each call so both sides agree on what the conversation is.
    private func syncChat(_ client: LocalEngineClient) async throws {
        struct Loaded: Decodable { let length: Int }
        _ = try await client.call(
            "chat.load",
            args: [
                "characterName": .string(characterName),
                "messages": .array(messages.map { message in
                    .object([
                        "name": .string(message.isUser ? "User" : characterName),
                        "is_user": .bool(message.isUser),
                        "mes": .string(message.text),
                    ])
                }),
            ],
            as: Loaded.self
        )
    }
}
