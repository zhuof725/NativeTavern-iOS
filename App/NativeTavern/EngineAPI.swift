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

/// One message in the assembled model prompt.
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

/// A reply produced by the core's own generation path.
struct GenerationReply: Decodable, Sendable {
    struct Message: Decodable, Sendable {
        let role: String
        let content: String
    }
    let messages: [Message]
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
}
