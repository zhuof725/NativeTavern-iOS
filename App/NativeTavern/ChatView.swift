import SwiftUI
import UIKit

/// A conversation in the reading column.
///
/// Layout follows the Apple Glass reference: the transcript scrolls under a
/// floating input island, the character's prose sits directly on the surface
/// with a name/meta line above it, and the user's turns are a single aligned
/// bubble. Markdown is rendered with the system parser so *italic* prose from
/// the character shows as emphasis instead of asterisks.
struct ChatView: View {
    @ObservedObject var app: AppModel
    let client: LocalEngineClient
    let target: ChatTarget
    let characterAvatar: String
    let reloadToken: Int

    @StateObject private var store: ChatStore
    @State private var editing: ChatMessage?
    @State private var editText = ""
    @State private var pendingDelete: ChatMessage?
    @State private var showingPrompt = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var historyOpen = false
    @State private var chats: [ChatSummary] = []
    @FocusState private var composerFocused: Bool

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
            transcript
            VStack(spacing: 6) {
                if let error = store.errorMessage {
                    errorBanner(error)
                }
                composer
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .navigationTitle(store.characterName.isEmpty ? target.title : store.characterName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(item: $editing) { message in
            editor(for: message)
        }
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
        .sheet(isPresented: $historyOpen, onDismiss: { Task { await loadChats() } }) {
            historySheet
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
        .onAppear {
            Task {
                await store.bind(fileName: target.fileName)
                await loadChats()
            }
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(store.messages.enumerated()), id: \.element.id) { index, message in
                        MessageBlock(
                            client: client,
                            message: message,
                            characterAvatar: characterAvatar,
                            characterName: store.characterName.isEmpty ? target.title : store.characterName,
                            showsDay: showsDaySeparator(at: index),
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
                        TypingIndicator(elapsed: store.elapsed)
                            .id("typing")
                    }
                    if store.messages.isEmpty && !store.busy {
                        emptyState
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 150)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.messages.count) { _, _ in
                if let last = store.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: store.busy) { _, busy in
                if busy {
                    withAnimation { proxy.scrollTo("typing", anchor: .bottom) }
                }
            }
        }
    }

    private func showsDaySeparator(at index: Int) -> Bool {
        guard index > 0 else { return store.messages.first?.sendDate.isEmpty == false }
        let previous = store.messages[index - 1].sendDate
        let current = store.messages[index].sendDate
        guard let a = MessageBlock.day(for: previous), let b = MessageBlock.day(for: current) else { return false }
        return a != b
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(character?.name ?? target.title)
                .font(.title2.weight(.bold))
            Text(ContentFormatter.plain(character?.description ?? ""))
                .font(.callout)
                .foregroundStyle(Glass.label2)
                .lineLimit(6)
        }
        .padding(.top, 8)
    }

    // MARK: Chrome

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                store.errorMessage = nil
            } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Glass.label3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.red.opacity(0.35), lineWidth: 0.5)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                showingPrompt = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Glass.pressed, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看提示词")

            TextField("输入消息…", text: $store.draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .focused($composerFocused)
                .font(.system(size: 15))
                .padding(.vertical, 8)

            if store.busy {
                Button {
                    Task { await store.stop() }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.9), in: Circle())
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("停止生成")
            } else {
                Button {
                    Task { await store.send() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(store.canSend ? Color.accentColor : Glass.pressed, in: Circle())
                        .foregroundStyle(store.canSend ? Color.white : Glass.label3)
                }
                .buttonStyle(.plain)
                .disabled(!store.canSend)
                .accessibilityLabel("发送")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glassIsland()
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            NavigationLink {
                HomeSettingsView(app: app)
            } label: {
                Image(systemName: "line.3.horizontal")
            }
            .accessibilityLabel("设置")
            NavigationLink {
                LibraryView(app: app, character: character)
            } label: {
                Image(systemName: "square.grid.2x2")
            }
            .accessibilityLabel("资料库")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    Task { await store.startNew() }
                } label: {
                    Label("新对话", systemImage: "square.and.pencil")
                }
                Button {
                    historyOpen = true
                } label: {
                    Label("聊天记录", systemImage: "clock.arrow.circlepath")
                }
                Button {
                    newName = store.fileName.replacingOccurrences(of: ".jsonl", with: "")
                    renaming = true
                } label: {
                    Label("重命名对话", systemImage: "pencil")
                }
                Divider()
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
                .disabled(store.busy || store.messages.isEmpty)
                Divider()
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
                                Text(chat.displayName)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer()
                                if chat.fileName == store.fileName {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            Text((chat.lastMessage.isEmpty ? chat.preview : chat.lastMessage)
                                .replacingOccurrences(of: "\n", with: " "))
                                .font(.caption)
                                .foregroundStyle(Glass.label2)
                                .lineLimit(2)
                            Text("\(chat.messageCount) 条")
                                .font(.caption2)
                                .foregroundStyle(Glass.label3)
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
                if chats.isEmpty {
                    ContentUnavailableView("还没有聊天记录", systemImage: "bubble.left")
                }
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
                .font(.system(size: 15))
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

    private func loadChats() async {
        chats = await app.chats(for: target.avatar)
    }
}

/// Settings entry point for the reading column: connection, engine, and the
/// library screens, without leaving the conversation.
struct HomeSettingsView: View {
    @ObservedObject var app: AppModel

    var body: some View {
        List {
            Section("连接") {
                NavigationLink {
                    SettingsView(app: app)
                } label: {
                    Label("模型连接与设置", systemImage: "antenna.radiowaves.left.and.right")
                }
            }
            Section("资料") {
                NavigationLink {
                    WorldInfoView(app: app)
                } label: {
                    Label("世界书", systemImage: "book.closed")
                }
                NavigationLink {
                    PresetsView(app: app)
                } label: {
                    Label("预设与生成参数", systemImage: "slider.horizontal.3")
                }
            }
            Section("引擎") {
                NavigationLink {
                    EngineLogView()
                } label: {
                    Label("引擎日志", systemImage: "doc.text.magnifyingglass")
                }
                switch app.engine.phase {
                case .transportReady(let status):
                    LabeledContent("酒馆核心", value: status.sillyTavernCoreReady ? "已运行" : "启动中")
                    LabeledContent("角色", value: "\(app.characters.count)")
                case .failed(let message):
                    Text(message).font(.footnote).foregroundStyle(.red)
                default:
                    Text("正在启动").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("菜单")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One message: a meta line (avatar, name, model/tokens/time) and the body.
private struct MessageBlock: View {
    let client: LocalEngineClient
    let message: ChatMessage
    let characterAvatar: String
    let characterName: String
    let showsDay: Bool
    let canSwipe: Bool
    let onSwipe: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsDay, let day = Self.day(for: message.sendDate) {
                Text(day)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Glass.label3)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
            if message.isUser {
                userBubble
            } else if message.isSystem {
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(Glass.label3)
                    .italic()
            } else {
                characterBlock
            }
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 48)
            Text(message.text)
                .font(.system(size: 15.5))
                .lineSpacing(3)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Glass.innerHighlight, lineWidth: 0.5)
                }
                .textSelection(.enabled)
        }
    }

    private var characterBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                EngineImage(client: client, path: "characters/\(characterAvatar)")
                    .frame(width: 24, height: 24)
                    .clipShape(Circle())
                Text(message.name.isEmpty ? characterName : message.name)
                    .font(.footnote.weight(.semibold))
                Spacer(minLength: 8)
                if let time = Self.clock(for: message.sendDate) {
                    Text(time)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(Glass.label3)
                }
            }
            renderedText
                .font(.system(size: 15.5))
                .lineSpacing(4)
                .textSelection(.enabled)
            if message.swipes.count > 1 {
                swipeControl
            }
        }
    }

    /// Markdown through the system parser: *prose* becomes emphasis.
    @ViewBuilder
    private var renderedText: some View {
        if let attributed = try? AttributedString(
            markdown: message.text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(message.text)
    }

    private var swipeControl: some View {
        HStack(spacing: 8) {
            Button {
                onSwipe("left")
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(!canSwipe)
            Text("\(min(message.swipeId + 1, message.swipes.count))/\(message.swipes.count)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(Glass.label3)
            Button {
                onSwipe("right")
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(!canSwipe)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Glass.label2)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Glass.pressed, in: Capsule())
    }

    static func date(_ raw: String) -> Date? {
        guard let value = Double(raw) else { return nil }
        return Date(timeIntervalSince1970: value > 1_000_000_000_000 ? value / 1000 : value)
    }

    static func day(for raw: String) -> String? {
        guard let date = date(raw) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: date)
    }

    static func clock(for raw: String) -> String? {
        guard let date = date(raw) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

private struct TypingIndicator: View {
    let elapsed: Int

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(elapsed > 0 ? "正在生成… \(elapsed)s" : "正在生成…")
                .font(.caption)
                .foregroundStyle(Glass.label2)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Glass.pressed, in: Capsule())
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
