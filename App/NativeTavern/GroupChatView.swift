import SwiftUI
import UIKit

/// A group conversation.
///
/// Group generation is upstream's own path (`Generate()` hands off to
/// `generateGroupWrapper()` when a group is selected), so this screen only has to
/// select the group, keep its chat open and send through the same call the single
/// character chat uses.
struct GroupChatView: View {
    @ObservedObject var app: AppModel
    let group: GroupSummary
    var onChanged: (() -> Void)?

    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var busy = false
    @State private var elapsed = 0
    @State private var error: String?
    @State private var chatId = ""
    @State private var chats: [GroupChatInfo] = []
    @State private var showingChats = false
    @State private var editing: ChatMessage?
    @State private var editText = ""
    @State private var pendingDelete: ChatMessage?
    @State private var renamingChat = false
    @State private var newChatName = ""
    @State private var ticker: Task<Void, Never>?

    private var members: [String] { group.enabledMembers }

    var body: some View {
        VStack(spacing: 0) {
            memberStrip
            transcript
            if let error {
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
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await newChat() }
                    } label: {
                        Label("新对话", systemImage: "plus.bubble")
                    }
                    Button { showingChats = true } label: {
                        Label("历史对话", systemImage: "clock.arrow.circlepath")
                    }
                    Divider()
                    Button {
                        Task { await send(forceMember: nil, regenerate: true) }
                    } label: {
                        Label("重新生成", systemImage: "arrow.clockwise")
                    }
                    .disabled(busy || messages.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingChats, onDismiss: { Task { await loadChats() } }) {
            chatsSheet
        }
        .sheet(item: $editing) { message in
            editor(for: message)
        }
        .alert("删除这条消息？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let message = pendingDelete {
                    pendingDelete = nil
                    Task { await deleteMessage(message) }
                }
            }
        }
        .alert("重命名对话", isPresented: $renamingChat) {
            TextField("名称", text: $newChatName)
            Button("取消", role: .cancel) {}
            Button("保存") {
                let name = newChatName
                Task { await renameChat(to: name) }
            }
        }
        .task { await open() }
        .onDisappear { ticker?.cancel() }
    }

    // MARK: Member strip

    private var memberStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(members, id: \.self) { avatar in
                    Button {
                        Task { await send(forceMember: avatar, regenerate: false) }
                    } label: {
                        VStack(spacing: 4) {
                            EngineImage(client: app.client, path: "characters/\(avatar)")
                                .frame(width: 40, height: 40)
                                .clipShape(Circle())
                                .overlay { Circle().strokeBorder(Color.secondary.opacity(0.25)) }
                            Text(app.character(avatar: avatar)?.name ?? avatar)
                                .font(.caption2)
                                .lineLimit(1)
                                .frame(maxWidth: 56)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(messages) { message in
                        GroupMessageRow(
                            client: app.client,
                            message: message,
                            avatar: avatarFor(message),
                            canSwipe: !busy,
                            onSwipe: { direction in
                                Task { await swipe(message, direction: direction) }
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
                            Divider()
                            Button(role: .destructive) {
                                pendingDelete = message
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                    if busy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(elapsed > 0 ? "正在生成… \(elapsed)s" : "正在生成…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .id("typing")
                    }
                    if messages.isEmpty && !busy {
                        Text("发一条消息，\(group.enabledMembers.count) 位角色会按“\(GroupOptions.strategies[min(group.activationStrategy, GroupOptions.strategies.count - 1)])”策略回应。点上方头像可以让指定角色先回答。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 30)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 14)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: busy) { _, value in
                if value { withAnimation { proxy.scrollTo("typing", anchor: .bottom) } }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("发消息给群聊…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .disabled(busy)
            if busy {
                Button {
                    Task { await stop() }
                } label: {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .accessibilityLabel("停止生成")
            } else {
                Button {
                    Task { await send(forceMember: nil, regenerate: false) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("发送")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var chatsSheet: some View {
        NavigationStack {
            List {
                ForEach(chats) { chat in
                    Button {
                        showingChats = false
                        Task { await openChat(chat.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(chat.id).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                Spacer()
                                if chat.id == chatId {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                                }
                            }
                            Text(chat.lastMessage.isEmpty ? chat.preview : chat.lastMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text("\(chat.messageCount) 条")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await deleteChat(chat.id) }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button {
                            newChatName = chat.id
                            renamingChat = true
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
            }
            .overlay {
                if chats.isEmpty { ContentUnavailableView("还没有群聊记录", systemImage: "bubble.left") }
            }
            .navigationTitle("历史对话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showingChats = false }
                }
            }
            .task { await loadChats() }
        }
    }

    private func editor(for message: ChatMessage) -> some View {
        NavigationStack {
            TextEditor(text: $editText)
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
                            Task { await editMessage(id: id, text: text) }
                        }
                    }
                }
        }
    }

    // MARK: Actions

    private func open() async {
        guard let client = app.client else { return }
        busy = true
        do {
            let snapshot = try await client.call("group.open", args: ["id": .string(group.id)], as: GroupSnapshot.self)
            messages = snapshot.messages
            chatId = snapshot.chatId ?? ""
            await loadChats()
        } catch {
            self.error = "打开群聊失败：\(error.localizedDescription)"
        }
        busy = false
    }

    private func send(forceMember: String?, regenerate: Bool) async {
        guard let client = app.client, !busy else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !regenerate && text.isEmpty && forceMember == nil { return }

        busy = true
        error = nil
        startTicker()
        if !text.isEmpty {
            draft = ""
            messages.append(ChatMessage(
                id: messages.count, name: "你", isUser: true, isSystem: false,
                text: text, swipes: [], swipeId: 0, sendDate: ""
            ))
        }
        do {
            var args: [String: JSONValue] = ["text": .string(text)]
            if let forceMember {
                // A member chip: that character speaks first. Upstream's group
                // generator takes the chosen member by avatar.
                args["forceMember"] = .string(forceMember)
            }
            let reply = try await client.call("group.send", args: args, as: GroupSnapshot.self)
            messages = reply.messages
            if let failure = reply.error, !failure.isEmpty { error = failure }
        } catch {
            self.error = error.localizedDescription
        }
        stopTicker()
        busy = false
    }

    private func swipe(_ message: ChatMessage, direction: String) async {
        guard let client = app.client, !busy else { return }
        busy = true
        startTicker()
        do {
            let reply = try await client.call(
                "group.swipe",
                args: ["id": .number(Double(message.id)), "direction": .string(direction)],
                as: GroupSnapshot.self
            )
            messages = reply.messages
            if let failure = reply.error, !failure.isEmpty { error = failure }
        } catch {
            self.error = error.localizedDescription
        }
        stopTicker()
        busy = false
    }

    private func editMessage(id: Int, text: String) async {
        guard let client = app.client else { return }
        do {
            let reply = try await client.call(
                "group.message.edit",
                args: ["id": .number(Double(id)), "text": .string(text)],
                as: GroupSnapshot.self
            )
            messages = reply.messages
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteMessage(_ message: ChatMessage) async {
        guard let client = app.client else { return }
        do {
            let reply = try await client.call(
                "group.message.delete",
                args: ["id": .number(Double(message.id))],
                as: GroupSnapshot.self
            )
            messages = reply.messages
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func stop() async {
        guard let client = app.client else { return }
        struct Stopped: Decodable { let stopped: Bool }
        _ = try? await client.call("generate.stop", as: Stopped.self)
        stopTicker()
        busy = false
    }

    private func newChat() async {
        guard let client = app.client else { return }
        busy = true
        do {
            let reply = try await client.call("group.chat.new", args: ["id": .string(group.id)], as: GroupSnapshot.self)
            messages = reply.messages
            chatId = reply.chatId ?? ""
            await loadChats()
            onChanged?()
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }

    private func openChat(_ id: String) async {
        guard let client = app.client else { return }
        busy = true
        do {
            let reply = try await client.call(
                "group.chat.open",
                args: ["id": .string(group.id), "chatId": .string(id)],
                as: GroupSnapshot.self
            )
            messages = reply.messages
            chatId = reply.chatId ?? id
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }

    private func deleteChat(_ id: String) async {
        guard let client = app.client else { return }
        struct Deleted: Decodable { let deleted: String }
        _ = try? await client.call(
            "group.chat.delete",
            args: ["id": .string(group.id), "chatId": .string(id)],
            as: Deleted.self
        )
        await loadChats()
        onChanged?()
    }

    private func renameChat(to newName: String) async {
        guard let client = app.client, !chatId.isEmpty else { return }
        struct Renamed: Decodable { let chatId: String }
        if let reply = try? await client.call(
            "group.chat.rename",
            args: ["id": .string(group.id), "chatId": .string(chatId), "newName": .string(newName)],
            as: Renamed.self
        ) {
            chatId = reply.chatId
        }
        await loadChats()
    }

    private func loadChats() async {
        guard let client = app.client else { return }
        if let reply = try? await client.call("group.chats", args: ["id": .string(group.id)], as: GroupChatListReply.self) {
            chats = reply.chats
            if chatId.isEmpty { chatId = reply.current }
        }
    }

    private func startTicker() {
        elapsed = 0
        ticker?.cancel()
        ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                elapsed += 1
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    /// A group message is attributed by name; the avatar follows it.
    private func avatarFor(_ message: ChatMessage) -> String {
        if message.isUser { return "" }
        let match = app.characters.first { $0.name == message.name }
        return match?.avatar ?? members.first ?? ""
    }
}

private struct GroupMessageRow: View {
    let client: LocalEngineClient
    let message: ChatMessage
    let avatar: String
    let canSwipe: Bool
    let onSwipe: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.isUser { Spacer(minLength: 40) }
            if !message.isUser && !avatar.isEmpty {
                EngineImage(client: client, path: "characters/\(avatar)")
                    .frame(width: 30, height: 30)
                    .clipShape(Circle())
            }
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                Text(message.isUser ? "你" : (message.name.isEmpty ? "角色" : message.name))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(
                        message.isUser ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                if message.swipes.count > 1 {
                    HStack(spacing: 8) {
                        Button { onSwipe("left") } label: { Image(systemName: "chevron.left") }
                            .disabled(!canSwipe)
                        Text("\(min(message.swipeId + 1, message.swipes.count))/\(message.swipes.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button { onSwipe("right") } label: { Image(systemName: "chevron.right") }
                            .disabled(!canSwipe)
                    }
                    .buttonStyle(.borderless)
                }
            }
            if !message.isUser { Spacer(minLength: 40) }
        }
    }
}
