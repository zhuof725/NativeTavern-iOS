import Foundation
import Combine

@MainActor
final class EmbeddedEngine: ObservableObject {
    enum Phase {
        case idle
        case starting
        case transportReady(EngineStatus)
        case failed(String)
        case exited(Int32)
    }

    static let shared = EmbeddedEngine()
    @Published private(set) var phase: Phase = .idle
    private var attemptedStart = false
    private var workerExit: Int32?

    private init() {}

    func start() {
        guard !attemptedStart else { return }
        attemptedStart = true
        phase = .starting
        do {
            guard let folder = Bundle.main.url(forResource: "Engine", withExtension: nil) else {
                throw LocalEngineFailure("安装包中没有本地引擎资源。")
            }
            let entry = folder.appendingPathComponent("boot.mjs")
            guard FileManager.default.fileExists(atPath: entry.path) else {
                throw LocalEngineFailure("安装包中缺少 boot.mjs。")
            }
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            let data = support.appendingPathComponent("NativeTavern", isDirectory: true)
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ], ofItemAtPath: data.path)
            let launchID = UUID().uuidString
            let entryPath = entry.path
            let dataPath = data.path
            let worker = Thread { [weak self] in
                let code = entryPath.withCString { script in
                    dataPath.withCString { root in
                        launchID.withCString { identity in
                            NTStartEmbeddedNode(script, root, identity)
                        }
                    }
                }
                Task { @MainActor in
                    self?.workerExit = code
                    self?.phase = code == -4
                        ? .failed("尚未确认此设备支持所选 NodeMobile 运行时，已停止启动。")
                        : .exited(code)
                }
            }
            worker.name = "NativeTavern.Node"
            worker.stackSize = 8 * 1024 * 1024
            worker.start()
            Task { await discover(in: data, launchID: launchID) }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func discover(in directory: URL, launchID: String) async {
        let file = directory.appendingPathComponent("endpoint.json")
        do {
            for _ in 0..<200 {
                if workerExit != nil { return }
                if let data = try? Data(contentsOf: file),
                   let endpoint = try? JSONDecoder().decode(EngineEndpoint.self, from: data),
                   endpoint.launchID == launchID {
                    let client = try LocalEngineClient(endpoint: endpoint, launchID: launchID)
                    let status = try await client.status()
                    if workerExit == nil { phase = .transportReady(status) }
                    return
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw LocalEngineFailure("本地引擎启动超时；没有连接外部后端。")
        } catch {
            if workerExit == nil { phase = .failed(error.localizedDescription) }
        }
    }
}
