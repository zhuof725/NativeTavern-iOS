import Foundation
import Combine

/// App-wide state: the embedded engine and the few things the hosted page
/// cannot answer for itself (launch progress, engine log, failures).
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case starting(String)
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .starting("正在启动本地引擎…")
    @Published var errorMessage: String? {
        didSet { if errorMessage != nil { showErrorAlert = true } }
    }
    @Published var showErrorAlert = false

    let engine = EmbeddedEngine.shared

    var client: LocalEngineClient? { engine.client }
    var isReady: Bool { phase == .ready }

    func boot() async {
        engine.start()
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            if let client = engine.client {
                if let status = try? await client.status(), status.sillyTavernCoreReady {
                    // The hosted page loads its own settings; nothing is fetched
                    // here, so the interface appears as soon as the core is up.
                    phase = .ready
                    return
                }
                phase = .starting("正在加载原版酒馆核心…")
            } else {
                phase = .starting("正在启动本地运行时…")
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        phase = .failed("本地引擎启动超时。可在“引擎日志”查看原因。")
    }
}
