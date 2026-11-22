import Foundation

/// JSON-RPC call into the local engine, which runs the original SillyTavern core.
struct EngineCall: Encodable {
    let id: String
    let method: String
    let args: [String: JSONValue]

    init(method: String, args: [String: JSONValue] = [:]) {
        self.id = UUID().uuidString
        self.method = method
        self.args = args
    }
}

/// Minimal JSON value so calls can carry mixed argument shapes.
enum JSONValue: Encodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct RemoteFailure: Decodable {
    let code: String
    let message: String
}

struct EngineReply<Result: Decodable>: Decodable {
    let id: String?
    let result: Result?
    let error: RemoteFailure?
}

// MARK: - Characters

struct CharacterSummary: Decodable, Identifiable, Hashable {
    let name: String
    let avatar: String
    let description: String
    let personality: String
    let scenario: String
    let firstMes: String
    let mesExample: String
    let creatorNotes: String
    let systemPrompt: String
    let postHistoryInstructions: String
    let tags: [String]
    let hasCharacterBook: Bool
    let chat: String
    let fav: Bool
    let dateAdded: Double

    var id: String { avatar }
}

struct CharacterListReply: Decodable { let characters: [CharacterSummary] }
struct CharacterReply: Decodable { let character: CharacterSummary; let avatar: String? }

/// Editable fields of a character card. Kept separate from the summary so the
/// editor can hold partial text while typing.
struct CharacterDraft {
    var name: String = ""
    var description: String = ""
    var personality: String = ""
    var scenario: String = ""
    var firstMes: String = ""
    var mesExample: String = ""
    var creatorNotes: String = ""
    var systemPrompt: String = ""
    var postHistoryInstructions: String = ""
    var creator: String = ""
    var characterVersion: String = ""
    var tags: String = ""
    var talkativeness: String = "0.5"

    init() {}

    init(_ character: CharacterSummary) {
        name = character.name
        description = character.description
        personality = character.personality
        scenario = character.scenario
        firstMes = character.firstMes
        mesExample = character.mesExample
        creatorNotes = character.creatorNotes
        systemPrompt = character.systemPrompt
        postHistoryInstructions = character.postHistoryInstructions
        tags = character.tags.joined(separator: ", ")
    }

    var isValid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var tagList: [String] {
        tags.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var json: [String: JSONValue] {
        [
            "name": .string(name),
            "description": .string(description),
            "personality": .string(personality),
            "scenario": .string(scenario),
            "firstMes": .string(firstMes),
            "mesExample": .string(mesExample),
            "creatorNotes": .string(creatorNotes),
            "systemPrompt": .string(systemPrompt),
            "postHistoryInstructions": .string(postHistoryInstructions),
            "creator": .string(creator),
            "characterVersion": .string(characterVersion),
            "tags": .array(tagList.map { JSONValue.string($0) }),
            "talkativeness": .string(talkativeness),
        ]
    }
}

// MARK: - Chats

struct ChatSummary: Decodable, Identifiable, Hashable {
    let fileName: String
    let fileId: String
    let preview: String
    let lastMessage: String
    let messageCount: Int
    let lastUpdated: String

    var id: String { fileName }
    var displayName: String {
        fileId.isEmpty ? fileName.replacingOccurrences(of: ".jsonl", with: "") : fileId
    }
}

struct ChatListReply: Decodable { let chats: [ChatSummary] }

struct ChatMessage: Decodable, Identifiable, Equatable {
    let id: Int
    let name: String
    let isUser: Bool
    let isSystem: Bool
    let text: String
    let swipes: [String]
    let swipeId: Int
    let sendDate: String
}

struct ChatSnapshot: Decodable {
    let messages: [ChatMessage]
    let fileName: String
    let characterName: String
    let userName: String
}

struct SendReply: Decodable {
    let messages: [ChatMessage]
    let fileName: String?
    let characterName: String?
    let userName: String?
    let error: String?
}

// MARK: - World info

struct WorldBookSummary: Decodable, Identifiable, Hashable {
    let name: String
    let active: Bool
    var id: String { name }
}

struct WorldBookListReply: Decodable {
    let books: [WorldBookSummary]
    let active: [String]
}

struct WorldInfoEntry: Decodable, Identifiable, Hashable {
    let uid: Int
    let comment: String?
    let key: [String]?
    let keysecondary: [String]?
    let content: String?
    let constant: Bool?
    let selective: Bool?
    let order: Int?
    let position: Int?
    let depth: Int?
    let probability: Int?
    let useProbability: Bool?
    let disable: Bool?
    let group: String?
    let role: String?
    let vectorized: Bool?
    let useRegex: Bool?
    let excludeRecursion: Bool?

    var id: Int { uid }
    var keysText: String { (key ?? []).joined(separator: ", ") }
    var title: String {
        let value = (comment ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { return value }
        return keysText.isEmpty ? "条目 \(uid)" : keysText
    }
}

struct WorldInfoData: Decodable {
    let entries: [String: WorldInfoEntry]?
}

struct WorldInfoBook: Decodable {
    let name: String
    let data: WorldInfoData?
}

struct WorldInfoCreateReply: Decodable { let name: String }
struct WorldInfoEntryReply: Decodable { let uid: Int; let book: String }

// MARK: - Presets and prompts

struct PresetSummary: Decodable, Identifiable, Hashable {
    let name: String
    let temperature: Double
    let maxTokens: Int
    let topP: Double
    let frequencyPenalty: Double
    let presencePenalty: Double
    let chatCompletionSource: String
    let model: String

    var id: String { name }
}

struct PresetListReply: Decodable {
    let presets: [PresetSummary]
    let current: String
}

struct PromptEntry: Decodable, Identifiable, Hashable {
    let identifier: String
    let name: String
    let role: String
    let content: String
    let systemPrompt: Bool
    let marker: Bool
    var enabled: Bool

    var id: String { identifier }
}

struct PromptListReply: Decodable { let prompts: [PromptEntry] }

struct ToggleReply: Decodable { let identifier: String; let enabled: Bool }

// MARK: - Settings and personas

struct SettingsSnapshot: Decodable, Equatable {
    let userName: String
    let userAvatar: String
    let mainApi: String
    let source: String
    let currentModel: String
    let customUrl: String
    let customModel: String
    let openaiModel: String
    let reverseProxy: String
    let maxContext: Int
    let maxTokens: Int
    let temperature: Double
    let topP: Double
    let topK: Double
    let frequencyPenalty: Double
    let presencePenalty: Double
    let stream: Bool
    let presetName: String
    let presetNames: [String]
    let worldNames: [String]
}

struct PersonaSummary: Decodable, Identifiable, Hashable {
    let avatar: String
    let name: String
    let description: String
    let title: String
    let current: Bool
    var id: String { avatar }
}

struct PersonaListReply: Decodable { let personas: [PersonaSummary] }

// MARK: - Prompt inspector

struct PromptMessage: Decodable, Sendable {
    let role: String
    let content: String
    let name: String?
}

struct BuiltPrompt: Decodable, Sendable {
    let prompt: [PromptMessage]
    let worldInfo: WorldInfoSlice

    struct WorldInfoSlice: Decodable, Sendable {
        let before: String
        let after: String
    }
}

struct GenerationReply: Decodable, Sendable {
    struct Message: Decodable, Sendable {
        let role: String
        let content: String
    }
    let messages: [Message]
}

extension LocalEngineClient {
    /// Calls the engine's original-core API. The transport authenticates the
    /// request; the core itself is upstream SillyTavern code running in-process.
    func call<Result: Decodable>(_ method: String, args: [String: JSONValue] = [:], as type: Result.Type) async throws -> Result {
        let call = EngineCall(method: method, args: args)
        var request = URLRequest(url: baseURL.appendingPathComponent("engine/rpc"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(call)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LocalEngineFailure("本地引擎没有返回 HTTP 响应。")
        }
        let reply = try JSONDecoder().decode(EngineReply<Result>.self, from: data)
        if let error = reply.error { throw LocalEngineFailure("\(error.code): \(error.message)") }
        guard http.statusCode == 200, reply.id == call.id, let result = reply.result else {
            throw LocalEngineFailure("本地引擎响应与当前请求不匹配。")
        }
        return result
    }

    /// Fetches a file from the core's own HTTP surface (character avatars,
    /// persona images). The request carries the same per-launch token.
    func fetch(path: String) async throws -> Data {
        let encoded = path.split(separator: "/").map { segment in
            String(segment).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(segment)
        }.joined(separator: "/")
        guard let url = URL(string: baseURL.absoluteString + "/st/" + encoded) else {
            throw LocalEngineFailure("无效的资源路径。")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else {
            throw LocalEngineFailure("资源不可用。")
        }
        return data
    }
}
