import Foundation

struct EngineEndpoint: Decodable {
    let protocolVersion: Int
    let launchID: String
    let url: String
    let token: String

    func validatedURL(expectedLaunchID: String) throws -> URL {
        guard protocolVersion == 1, launchID == expectedLaunchID,
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

    init(endpoint: EngineEndpoint, launchID: String) throws {
        baseURL = try endpoint.validatedURL(expectedLaunchID: launchID)
        token = endpoint.token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    func status() async throws -> EngineStatus {
        struct Call: Encodable {
            let id: String
            let method = "engine.status"
            let args: [String: String] = [:]
        }
        struct RemoteFailure: Decodable { let code: String; let message: String }
        struct Reply: Decodable {
            let id: String?
            let result: EngineStatus?
            let error: RemoteFailure?
        }
        let id = UUID().uuidString
        var request = URLRequest(url: baseURL.appendingPathComponent("rpc"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(Call(id: id))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LocalEngineFailure("本地引擎没有返回 HTTP 响应。")
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        if let error = reply.error { throw LocalEngineFailure("\(error.code): \(error.message)") }
        guard http.statusCode == 200, reply.id == id,
              let result = reply.result, result.protocolVersion == 1 else {
            throw LocalEngineFailure("本地引擎响应与当前请求不匹配。")
        }
        return result
    }
}
