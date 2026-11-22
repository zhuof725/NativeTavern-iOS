import SwiftUI
import UIKit

/// A conversation, drawn in the reference's reading layout.
///
/// The header is the conversation itself: back on the left, the title centred
/// with the model underneath, actions on the right. Messages are prose on the
/// surface — no bubble for the character — and the composer floats at the bottom
/// with the context usage line inside it.
struct ChatView: View {
    @ObservedObject var app: AppModel
    let client: LocalEngineClient
    let target: ChatTarget
    let characterAvatar: String
    let reloadToken: Int

    @ObservedObject private var reading = ReadingPreferences.shared
    @StateObject private var store: ChatStore

    @Environment(\.dismiss) private var dismiss
    @State private var editing: ChatMessage?
    @State private var editText = ""
    @State private var pendingDelete: ChatMessage?
    @State private var showingPrompt = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var historyOpen = false
    @State private var chats: [ChatSummary] = []
    @State private var tokens = 0
    @State private var tokenLimit = 8192
    @State private var messageIndex = 1
    @State private var showingSettings = false

    init(app: AppModel, client: LocalEngineClient, target: ChatTarget, characterAvatar: String, reloadToken: Int) {
        self.app = app
        self.client = client
        self.target = target
        self.characterAvatar = characterAvatar
        self.reloadToken = reloadToken
        _store = StateObject(wrappedValue: ChatStore(client: client, avatar: target.avatar))
    }

    private var character: CharacterSummary? { app.character(avatar: target.avatar) }

    var body: some View {
        ZStack(alignment: .bottom) {
            background
            transcript
            VStack(spacing: 0) {
                if let error = store.errorMessage {
                    errorBanner(error)
                }
                composer
            }
            .frame(maxWidth: reading.maxLineWidth)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar { toolbarContent }
        .tint(reading.accent.color)
        .sheet(item: $editing) { message in editor(for: message) }
        .sheet(isPresented: $showingPrompt) {
            NavigationStack {
                PromptPreviewView(client: client, character: character)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showingPrompt = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $historyOpen, onDismiss: { Task { await loadChats() } }) { historySheet }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsHomeView(app: app) }
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
                Task {
                    await app.renameChat(avatar: target.avatar, fileName: file, newName: name)
                    await loadChats()
                }
            }
        }
        .task {
            await reading.load(from: client)
            if store.messages.isEmpty && store.fileName.isEmpty {
                if let fileName = target.fileName {
                    await store.open(fileName: fileName)
                } else {
                    await store.startNew()
                }
            }
            await loadChats()
            await refreshTokens()
        }
        .onChange(of: store.messages.count) { _, _ in
            Task { await refreshTokens() }
        }
    }

    // MARK: Background

    @ViewBuilder
    private var background: some View {
        if reading.background.isEmpty {
            Color(red: 0.04, green: 0.04, blue: 0.05).ignoresSafeArea()
        } else {
            EngineImage(client: client, path: "backgrounds/\(reading.background)")
                .ignoresSafeArea()
                .overlay(Color.black.opacity(0.55).ignoresSafeArea())
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    Color.clear.frame(height: 8)
                    ForEach(store.messages) { message in
                        ChatMessageView(
                            message: message,
                            characterName: store.characterName.isEmpty ? target.title : store.characterName,
                            avatarPath: "characters/\(characterAvatar)",
                            client: client,
                            style: reading.style,
                            bodySize: reading.bodySize,
                            showsInfo: reading.messageInfo == "always",
                            isLast: message.id == store.messages.last?.id,
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
                            Text(store.elapsed > 0 ? "正在生成… \(store.elapsed)s" : "正在生成…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .id("typing")
                    }
                    if store.messages.isEmpty && !store.busy {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(character?.name ?? target.title)
                                .font(.title3.weight(.semibold))
                            Text(ContentFormatter.plain(character?.description ?? ""))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(8)
                        }
                        .padding(.top, 8)
                    }
                }
                .frame(maxWidth: reading.maxLineWidth, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 150)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.messages.count) { _, _ in
                guard let last = store.messages.last else { return }
                withAnimation(reading.animation) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: store.busy) { _, busy in
                if busy { withAnimation { proxy.scrollTo("typing", anchor: .bottom) } }
            }
        }
    }

    // MARK: Composer

    private var contextLine: String {
        let used = min(100, Int(Double(tokens) / Double(max(tokenLimit, 1)) * 100))
        let formattedTokens = tokens >= 1000 ? String(format: "%.1fk", Double(tokens) / 1000) : "\(tokens)"
        let formattedLimit = tokenLimit >= 1000 ? "\(tokenLimit / 1000)k" : "\(tokenLimit)"
        return "上下文已用 \(used)% · \(formattedTokens) / \(formattedLimit)"
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(contextLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            HStack(alignment: .bottom, spacing: 10) {
                CircleButton(symbol: "plus", accent: reading.accent.color) {
                    showingPrompt = true
                }
                CircleButton(symbol: "slash", accent: reading.accent.color, isText: true) {
                    store.draft += "/"
                }

                TextField("发消息…", text: $store.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .font(reading.bodyFont)
                    .padding(.vertical, 8)
                    .disabled(store.busy)

                if store.busy {
                    Button {
                        Task { await store.stop() }
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 38, height: 38)
                            .background(Color.white, in: Circle())
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        Task { await store.send() }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 38, height: 38)
                            .background(store.canSend ? reading.accent.color : Color.secondary.opacity(0.28), in: Circle())
                            .foregroundStyle(store.canSend ? Color.white : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.canSend)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(reading.blur ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color(white: 0.11)))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                }
        }
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                store.errorMessage = nil
            } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.bottom, 6)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(store.characterName.isEmpty ? target.title : store.characterName)
                    .font(.headline)
                Button {
                    showingSettings = true
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(store.errorMessage == nil ? Color.green : Color.red)
                            .frame(width: 6, height: 6)
                        Text(app.settings?.currentModel.isEmpty == false
                             ? (app.settings?.currentModel ?? "")
                             : modelLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.down").font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { Task { await store.startNew() } } label: {
                    Label("新对话", systemImage: "square.and.pencil")
                }
                Button { historyOpen = true } label: {
                    Label("聊天记录", systemImage: "clock.arrow.circlepath")
                }
                Button {
                    newName = store.fileName.replacingOccurrences(of: ".jsonl", with: "")
                    renaming = true
                } label: {
                    Label("重命名对话", systemImage: "pencil")
                }
                Divider()
                Button { Task { await store.continueLast() } } label: {
                    Label("继续生成", systemImage: "text.append")
                }
                .disabled(store.busy || store.messages.isEmpty)
                Button { Task { await store.regenerateLast() } } label: {
                    Label("重新生成", systemImage: "arrow.clockwise")
                }
                .disabled(store.busy || store.messages.isEmpty)
                Divider()
                Button { showingPrompt = true } label: {
                    Label("查看最终提示词", systemImage: "text.alignleft")
                }
                Button { showingSettings = true } label: {
                    Label("设置", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
    }

    private var modelLabel: String {
        guard let source = app.settings?.source else { return "未连接" }
        let names: [String: String] = [
            "openai": "OpenAI", "custom": "自定义", "claude": "Claude",
            "openrouter": "OpenRouter", "deepseek": "DeepSeek", "groq": "Groq",
        ]
        return names[source] ?? source
    }

    // MARK: Data

    private func refreshTokens() async {
        if let reply = try? await client.call("chat.tokens", as: TokenReply.self) {
            tokens = reply.tokens
        }
        tokenLimit = app.settings?.maxContext ?? 8192
    }

    private func loadChats() async {
        chats = await app.chats(for: target.avatar)
    }

    private var historySheet: some View {
        NavigationStack {
            List {
                ForEach(chats) { chat in
                    Button {
                        historyOpen = false
                        Task { await store.open(fileName: chat.fileName) }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(chat.displayName).font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary).lineLimit(1)
                                Spacer()
                                if chat.fileName == store.fileName {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(reading.accent.color)
                                }
                            }
                            Text((chat.lastMessage.isEmpty ? chat.preview : chat.lastMessage)
                                .replacingOccurrences(of: "\n", with: " "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Text("\(chat.messageCount) 条")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task {
                                await app.deleteChat(avatar: target.avatar, fileName: chat.fileName)
                                await loadChats()
                            }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
            .overlay {
                if chats.isEmpty { ContentUnavailableView("还没有聊天记录", systemImage: "bubble.left") }
            }
            .navigationTitle("聊天记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { historyOpen = false }
                }
            }
            .task { await loadChats() }
        }
    }

    private func editor(for message: ChatMessage) -> some View {
        NavigationStack {
            TextEditor(text: $editText)
                .font(reading.bodyFont)
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
                            let text = editText
                            editing = nil
                            Task { await store.edit(messageId: id, text: text) }
                        }
                    }
                }
        }
    }
}

private struct TokenReply: Decodable {
    let tokens: Int
    let messages: Int
}

private struct CircleButton: View {
    let symbol: String
    var accent: Color = .accentColor
    var isText = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isText {
                    Text("/").font(.system(size: 17, weight: .medium))
                } else {
                    Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                }
            }
            .frame(width: 38, height: 38)
            .background(Color.secondary.opacity(0.14), in: Circle())
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}
