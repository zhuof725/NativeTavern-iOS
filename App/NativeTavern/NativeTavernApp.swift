import SwiftUI

@main
@MainActor
struct NativeTavernApp: App {
    @StateObject private var engine = EmbeddedEngine.shared

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack {
                    ContentUnavailableView("角色库尚未接入", systemImage: "person.crop.square", description:
                        Text("原生工程已建立。角色卡导入和原版数据适配尚未完成，不展示虚构角色。"))
                        .navigationTitle("角色")
                }
                .tabItem { Label("角色", systemImage: "person.crop.square") }

                NavigationStack {
                    ContentUnavailableView("聊天核心尚未接入", systemImage: "bubble.left.and.bubble.right", description:
                        Text("提示词、世界书、宏、预设与生成流程仍需从原版抽离；当前不会返回模拟回复。"))
                        .navigationTitle("聊天")
                }
                .tabItem { Label("聊天", systemImage: "bubble.left.and.bubble.right") }

                NavigationStack {
                    EngineView(engine: engine)
                }
                .tabItem { Label("本地引擎", systemImage: "cpu") }
            }
            .task { engine.start() }
        }
    }
}

private struct EngineView: View {
    @ObservedObject var engine: EmbeddedEngine

    var body: some View {
        List {
            Section("运行方式") {
                Label("NodeMobile 嵌入 App 进程", systemImage: "iphone")
                Label("仅与本机回环地址通信", systemImage: "lock.shield")
                Label("界面为 SwiftUI，不加载酒馆网页", systemImage: "rectangle.3.group")
            }
            Section("当前状态") {
                switch engine.phase {
                case .idle:
                    Text("尚未启动")
                case .starting:
                    HStack { ProgressView(); Text("正在启动 App 内运行时…") }
                case .transportReady(let status):
                    Label("本地运行时已响应", systemImage: "checkmark.circle")
                    LabeledContent("Node", value: status.runtime)
                    LabeledContent("协议", value: String(status.protocolVersion))
                    if !status.sillyTavernCoreReady {
                        Text("目前仅通信层就绪。SillyTavern 核心尚未集成，不能进行聊天。")
                            .foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                case .exited(let code):
                    Text("引擎线程已退出（\(code)）。运行时不能在同一进程内重复启动，请重新打开 App。")
                        .foregroundStyle(.red)
                }
            }
            Section {
                Text("这是原生架构开发原型，不是完成版酒馆。它不连接外部酒馆后端；将来使用在线模型时，模型 API 仍需要联网。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("本地引擎")
    }
}
