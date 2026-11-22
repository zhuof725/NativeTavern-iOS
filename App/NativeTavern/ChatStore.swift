import Foundation
import Combine

/// One open conversation. The core owns the chat; this object mirrors it for
/// display and forwards every action to the core's own operations.
@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var fileName: String = ""
    @Published private(set) var characterName: String = ""
    @Published private(set) var userName: String = "User"
    @Published private(set) var busy = false
    @Published private(set) var elapsed = 0
    @Published var draft: String = ""
    @Published var errorMessage: String?

    let avatar: String
    private let client: LocalEngineClient
    private var ticker: Task<Void, Never>?

    init(client: LocalEngineClient, avatar: String) {
        self.client = client
        self.avatar = avatar
    }

    /// Loads the chat the screen is bound to. Called on every appearance so the
    /// list's "latest conversation" is what the reading column shows.
    func bind(fileName desired: String?) async {
        guard !busy else { return }
        let wanted = desired ?? ""
        let current = fileName
        if wanted.isEmpty {
            if current.isEmpty && messages.isEmpty { await startNew() }
            return
        }
        if wanted == current && !messages.isEmpty { return }
        await open(fileName: wanted)
    }

    var canSend: Bool {
        !busy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func open(fileName: String?) async {
        beginWork()
        errorMessage = nil
        do {
            let snapshot = try await client.call(
                "chat.open",
                args: [
                    "avatar": .string(avatar),
                    "fileName": .string(fileName ?? ""),
                ],
                as: ChatSnapshot.self
            )
            apply(snapshot)
        } catch {
            errorMessage = error.localizedDescription
        }
        endWork()
    }

    func startNew() async {
        beginWork()
        errorMessage = nil
        do {
            let snapshot = try await client.call(
                "chat.new",
                args: ["avatar": .string(avatar)],
                as: ChatSnapshot.self
            )
            apply(snapshot)
        } catch {
            errorMessage = error.localizedDescription
        }
        endWork()
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        draft = ""
        errorMessage = nil
        // Show the user's turn immediately; the core appends the same text
        // before generating, and the reply below replaces this mirror.
        messages.append(ChatMessage(
            id: messages.count,
            name: userName,
            isUser: true,
            isSystem: false,
            text: text,
            swipes: [],
            swipeId: 0,
            sendDate: ""
        ))
        beginWork()
        do {
            let reply = try await client.call(
                "chat.send",
                args: ["text": .string(text)],
                as: SendReply.self
            )
            messages = reply.messages
            if let error = reply.error, !error.isEmpty {
                errorMessage = error
            }
            if let name = reply.characterName, !name.isEmpty { characterName = name }
            if let name = reply.userName, !name.isEmpty { userName = name }
        } catch {
            errorMessage = error.localizedDescription
        }
        endWork()
    }

    func continueLast() async {
        guard !busy, !messages.isEmpty else { return }
        beginWork()
        errorMessage = nil
        do {
            let reply = try await client.call(
                "chat.generate",
                args: ["type": .string("continue")],
                as: SendReply.self
            )
            messages = reply.messages
            if let error = reply.error, !error.isEmpty {
                errorMessage = error
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        endWork()
    }

    func regenerateLast() async {
        guard !busy, let last = messages.last, !last.isUser else { return }
        await swipe(messageId: last.id, direction: "right")
    }

    func swipe(messageId: Int, direction: String) async {
        guard !busy else { return }
        beginWork()
        errorMessage = nil
        do {
            let reply = try await client.call(
                "message.swipe",
                args: ["id": .number(Double(messageId)), "direction": .string(direction)],
                as: SendReply.self
            )
            messages = reply.messages
            if let error = reply.error, !error.isEmpty {
                errorMessage = error
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        endWork()
    }

    func edit(messageId: Int, text: String) async {
        beginWork()
        errorMessage = nil
        do {
            let snapshot = try await client.call(
                "message.edit",
                args: ["id": .number(Double(messageId)), "text": .string(text)],
                as: ChatSnapshot.self
            )
            apply(snapshot)
        } catch {
            errorMessage = error.localizedDescription
        }
        endWork()
    }

    func delete(messageId: Int) async {
        beginWork()
        errorMessage = nil
        do {
            let snapshot = try await client.call(
                "message.delete",
                args: ["id": .number(Double(messageId))],
                as: ChatSnapshot.self
            )
            apply(snapshot)
        } catch {
            errorMessage = error.localizedDescription
        }
        endWork()
    }

    func stop() async {
        do {
            struct Stopped: Decodable { let stopped: Bool }
            _ = try await client.call("generate.stop", as: Stopped.self)
        } catch {
            errorMessage = error.localizedDescription
        }
        endWork()
    }

    /// Drives the elapsed counter shown while a reply is pending.
    private func beginWork() {
        busy = true
        elapsed = 0
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                self?.elapsed += 1
            }
        }
    }

    private func endWork() {
        ticker?.cancel()
        ticker = nil
        busy = false
    }

    private func apply(_ snapshot: ChatSnapshot) {
        messages = snapshot.messages
        fileName = snapshot.fileName
        characterName = snapshot.characterName
        userName = snapshot.userName
    }
}
