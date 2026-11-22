import SwiftUI
import UIKit

struct ChatView: View {
    @ObservedObject var app: AppModel
    let client: LocalEngineClient
    let target: ChatTarget
    let characterAvatar: String

    @StateObject private var store: ChatStore
    @State private var editing: ChatMessage?
    @State private var editText = ""
    @State private var pendingDelete: ChatMessage?
    @State private var showingPrompt = false
    @State private var renaming = false
    @State private var newName = ""

    init(app: AppModel, client: LocalEngineClient, target: ChatTarget, characterAvatar: String) {
        self.app = app
        self.client = client
        self.target = target
        self.characterAvatar = characterAvatar
        _store = StateObject(wrappedValue: ChatStore(client: client, avatar: target.avatar))
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            if let error = store.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.08))
            }
            composer
        }
        .navigationTitle(store.characterName.isEmpty ? target.title : store.characterName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await store.startNew() }
                    } label: {
                        Label("新对话", systemImage: "plus.bubble")
                    }
                    Button {
                        newName = store.fileName.replacingOccurrences(of: ".jsonl", with: "")
                        renaming = true
                    } label: {
                        Label("重命名对话", systemImage: "pencil")
                    }
                    Button {
                        Task { await store.continueLast() }
                    } label: {
                        Label("继续生成", systemImage: "text.append")
                    }
                    .disabled(store.busy || store.messages.isEmpty)
                    Button {
                        Task { await store.regenerateLast() }
                    } label: {
                        Label("重新生成", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.busy)
                    Button {
                        showingPrompt = true
                    } label: {
                        Label("查看最终提示词", systemImage: "text.alignleft")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $editing) { message in
            NavigationStack {
                TextEditor(text: $editText)
                    .font(.body)
                    .padding(8)
                    .navigationTitle("编辑消息")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { editing = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                let id = message.id
                                editing = nil
                                Task { await store.edit(messageId: id, text: editText) }
                            }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingPrompt) {
            NavigationStack {
                PromptPreviewView(client: client, character: app.character(avatar: target.avatar))
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showingPrompt = false }
                        }
                    }
            }
        }
        .alert("删除这条消息？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let message = pendingDelete {
                    pendingDelete = nil
                    Task { await store.delete(messageId: message.id) }
                }
            }
        }
        .alert("重命名对话", isPresented: $renaming) {
            TextField("名称", text: $newName)
            Button("取消", role: .cancel) {}
            Button("保存") {
                let name = newName
                let file = store.fileName
                guard !file.isEmpty else { return }
                Task { await app.renameChat(avatar: target.avatar, fileName: file, newName: name) }
            }
        }
        .task {
            if store.messages.isEmpty && store.fileName.isEmpty {
                if let fileName = target.fileName {
                    await store.open(fileName: fileName)
                } else {
                    await store.startNew()
                }
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(store.messages) { message in
                        MessageRow(
                            client: client,
                            message: message,
                            characterAvatar: characterAvatar,
                            canSwipe: !store.busy,
                            onSwipe: { direction in
                                Task { await store.swipe(messageId: message.id, direction: direction) }
                            }
                        )
                        .id(message.id)
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = message.text
                            } label: {
                                Label("复制", systemImage: "doc.on.doc")
                            }
                            Button {
                                editText = message.text
                                editing = message
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            if !message.isUser {
                                Button {
                                    Task { await store.swipe(messageId: message.id, direction: "right") }
                                } label: {
                                    Label("重新生成", systemImage: "arrow.clockwise")
                                }
                            }
                            Divider()
                            Button(role: .destructive) {
                                pendingDelete = message
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                    if store.busy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在生成…").font(.caption).foregroundStyle(.secondary)
                        }
                        .id("typing")
                    }
                    if store.messages.isEmpty && !store.busy {
                        Text("还没有消息。发一条，原版核心会用它自己的角色卡、世界书和提示词顺序生成回复。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.messages.count) { _, _ in
                if let last = store.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: store.busy) { _, busy in
                if busy {
                    withAnimation { proxy.scrollTo("typing", anchor: .bottom) }
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("输入消息…", text: $store.draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .disabled(store.busy)
            if store.busy {
                Button {
                    Task { await store.stop() }
                } label: {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .accessibilityLabel("停止生成")
            } else {
                Button {
                    Task { await store.send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(!store.canSend)
                .accessibilityLabel("发送")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct MessageRow: View {
    let client: LocalEngineClient
    let message: ChatMessage
    let characterAvatar: String
    let canSwipe: Bool
    let onSwipe: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.isUser { Spacer(minLength: 40) }
            if !message.isUser {
                EngineImage(client: client, path: "characters/\(characterAvatar)")
                    .frame(width: 30, height: 30)
                    .clipShape(Circle())
            }
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                Text(message.isUser ? "你" : (message.name.isEmpty ? "角色" : message.name))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(message.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(
                        message.isUser ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                if message.swipes.count > 1 {
                    HStack(spacing: 8) {
                        Button {
                            onSwipe("left")
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(!canSwipe)
                        Text("\(min(message.swipeId + 1, message.swipes.count))/\(message.swipes.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button {
                            onSwipe("right")
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(!canSwipe)
                    }
                    .buttonStyle(.borderless)
                }
            }
            if !message.isUser { Spacer(minLength: 40) }
        }
    }
}

/// Shows the exact messages the core would send, plus the world info it injected.
struct PromptPreviewView: View {
    let client: LocalEngineClient
    let character: CharacterSummary?

    @State private var prompt: BuiltPrompt?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Section {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }
            if let prompt {
                let injected = prompt.worldInfo.before + prompt.worldInfo.after
                Section("世界书注入") {
                    if injected.isEmpty {
                        Text("本次没有条目被激活。").foregroundStyle(.secondary)
                    } else {
                        Text(injected).font(.footnote.monospaced())
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
            } else if loading {
                HStack { ProgressView(); Text("正在组装…") }
            } else {
                Text("点右上角刷新，核心会重新组装一次。")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("最终提示词")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    if loading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(loading)
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        error = nil
        var args: [String: JSONValue] = ["maxContext": .number(8192)]
        if let character {
            args["character"] = .object([
                "name": .string(character.name),
                "description": .string(character.description),
                "personality": .string(character.personality),
                "scenario": .string(character.scenario),
            ])
        }
        do {
            prompt = try await client.call("prompt.build", args: args, as: BuiltPrompt.self)
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
