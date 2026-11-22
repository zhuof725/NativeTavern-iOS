import Foundation

struct EngineEndpoint: Decodable {
    let protocolVersion: Int
    let launchID: String
    let url: String
    let token: String

    func validatedURL(expectedLaunchID: String) throws -> URL {
        guard protocolVersion >= 1, launchID == expectedLaunchID,
              token.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              let parts = URLComponents(string: url),
              parts.scheme == "http", parts.host == "127.0.0.1",
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              let port = parts.port, (1...65535).contains(port),
              let result = parts.url else {
            throw LocalEngineFailure("本地引擎握手无效或不属于本次启动。")
        }
        return result
    }
}

struct EngineStatus: Decodable, Sendable {
    let protocolVersion: Int
    let runtime: String
    let transportReady: Bool
    let sillyTavernCoreReady: Bool
    let capabilities: [String]
}

struct LocalEngineFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor LocalEngineClient {
    let baseURL: URL
    let token: String
    let session: URLSession

    /// The gateway origin, safe to read from any thread.
    nonisolated let origin: URL

    init(endpoint: EngineEndpoint, launchID: String) throws {
        baseURL = try endpoint.validatedURL(expectedLaunchID: launchID)
        token = endpoint.token
        origin = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        // Generation is synchronous from the caller's point of view: a request
        // stays open while the model writes.
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 900
        session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    func status() async throws -> EngineStatus {
        var request = URLRequest(url: baseURL.appendingPathComponent("engine/status"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LocalEngineFailure("本地引擎没有返回 HTTP 响应。")
        }
        guard http.statusCode == 200 else {
            throw LocalEngineFailure("本地引擎状态接口返回 \(http.statusCode)。")
        }
        let status = try JSONDecoder().decode(EngineStatus.self, from: data)
        guard status.protocolVersion >= 1, status.transportReady else {
            throw LocalEngineFailure("本地引擎响应与当前请求不匹配。")
        }
        return status
    }
}

/// Minimal JSON argument shapes for engine calls.
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
    /// One JSON-RPC call into the engine.
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
