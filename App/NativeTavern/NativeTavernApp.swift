import SwiftUI

@main
@MainActor
struct NativeTavernApp: App {
    @StateObject private var engine = EmbeddedEngine.shared

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack {
                    ChatView(engine: engine)
                }
                .tabItem { Label("聊天", systemImage: "bubble.left.and.bubble.right") }

                NavigationStack {
                    PromptInspectorView(engine: engine)
                }
                .tabItem { Label("提示词", systemImage: "text.alignleft") }

                NavigationStack {
                    EngineView(engine: engine)
                }
                .tabItem { Label("本地引擎", systemImage: "cpu") }
            }
            .task { engine.start() }
        }
    }
}

/// The chat surface. Messages are local state; the prompt that would be sent to
/// the model is produced by the original SillyTavern core inside the app.
private struct ChatView: View {
    @ObservedObject var engine: EmbeddedEngine
    @StateObject private var store: ChatStore

    init(engine: EmbeddedEngine) {
        self.engine = engine
        _store = StateObject(wrappedValue: ChatStore(engine: engine))
    }

    var body: some View {
        VStack(spacing: 0) {
            if case .transportReady(let status) = engine.phase, status.sillyTavernCoreReady {
                chatBody
            } else {
                ContentUnavailableView {
                    Label("本地引擎正在启动", systemImage: "cpu")
                } description: {
                    Text("原版酒馆核心正在 App 内加载。加载完成后即可使用世界书、宏和提示词组装。")
                }
                .frame(maxHeight: .infinity)
            }
        }
        .navigationTitle(store.characterName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await store.buildPrompt() }
                } label: {
                    if store.isBusy { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(store.isBusy || engine.client == nil)
            }
        }
    }

    private var chatBody: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(store.messages) { message in
                            MessageBubble(message: message, character: store.characterName)
                                .id(message.id)
                        }
                        if store.messages.isEmpty {
                            Text("还没有消息。发送一条，原版核心会用当前世界书和宏组装提示词。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.top, 24)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 16)
                }
                .onChange(of: store.messages.count) { _, _ in
                    if let last = store.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            if case .failed(let message) = store.status {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            HStack(spacing: 8) {
                TextField("输入消息…", text: $store.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await store.send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isBusy)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

private struct MessageBubble: View {
    let message: ChatStore.Message
    let character: String

    var body: some View {
        VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
            Text(message.isUser ? "你" : character)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(message.text)
                .padding(10)
                .background(message.isUser ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    }
}

/// Shows exactly what the original core would send to the model.
private struct PromptInspectorView: View {
    @ObservedObject var engine: EmbeddedEngine
    @StateObject private var store: ChatStore

    init(engine: EmbeddedEngine) {
        self.engine = engine
        _store = StateObject(wrappedValue: ChatStore(engine: engine))
    }

    var body: some View {
        List {
            if let prompt = store.lastPrompt {
                Section("世界书注入") {
                    if prompt.worldInfo.before.isEmpty && prompt.worldInfo.after.isEmpty {
                        Text("本次没有条目被激活。").foregroundStyle(.secondary)
                    } else {
                        Text(prompt.worldInfo.before + prompt.worldInfo.after)
                            .font(.footnote.monospaced())
                    }
                }
                Section("最终提示词（\(prompt.prompt.count) 条）") {
                    ForEach(Array(prompt.prompt.enumerated()), id: \.offset) { _, message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.role.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(message.content).font(.footnote.monospaced())
                        }
                        .padding(.vertical, 2)
                    }
                }
            } else {
                ContentUnavailableView("尚未组装", systemImage: "text.alignleft", description:
                    Text("在聊天页发送一条消息，或点刷新，这里会显示原版核心组装的提示词。"))
            }
        }
        .navigationTitle("提示词检查")
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
                Label("世界书、宏、提示词使用原版代码", systemImage: "checkmark.seal")
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
                    LabeledContent("酒馆核心", value: status.sillyTavernCoreReady ? "已运行" : "启动中")
                    LabeledContent("能力", value: "\(status.capabilities.count) 项")
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                case .exited(let code):
                    Text("引擎线程已退出（\(code)）。运行时不能在同一进程内重复启动，请重新打开 App。")
                        .foregroundStyle(.red)
                }
            }
            Section {
                Text("世界书扫描、宏展开和提示词组装由 App 内运行的原版酒馆核心完成。模型生成和角色卡导入仍在接入中。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("本地引擎")
    }
}
