import SwiftUI
import UniformTypeIdentifiers

/// Where a chat screen should open. `fileName` nil means "start a new chat".
struct ChatTarget: Hashable {
    let avatar: String
    let fileName: String?
    let title: String
}

struct CharactersView: View {
    @ObservedObject var app: AppModel
    @State private var query = ""
    @State private var creating = false
    @State private var editing: CharacterSummary?
    @State private var importing = false
    @State private var pendingDelete: CharacterSummary?

    private var filtered: [CharacterSummary] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return app.characters }
        return app.characters.filter { character in
            character.name.lowercased().contains(needle)
                || character.tags.contains { $0.lowercased().contains(needle) }
                || character.description.lowercased().contains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if filtered.isEmpty {
                    ContentUnavailableView {
                        Label(app.characters.isEmpty ? "还没有角色" : "没有匹配的角色", systemImage: "person.2")
                    } description: {
                        Text(app.characters.isEmpty
                             ? "新建一个角色，或从文件导入酒馆角色卡（PNG / JSON / CHARX）。"
                             : "换一个关键词试试。")
                    }
                    .padding(.top, 80)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 16) {
                        ForEach(filtered) { character in
                            NavigationLink(value: character) {
                                CharacterCardView(app: app, character: character)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    editing = character
                                } label: {
                                    Label("编辑", systemImage: "pencil")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    pendingDelete = character
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("角色")
            .searchable(text: $query, prompt: "搜索角色")
            .refreshable { await app.refreshCharacters() }
            .navigationDestination(for: CharacterSummary.self) { character in
                CharacterDetailView(app: app, character: character)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        importing = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .accessibilityLabel("导入角色卡")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        creating = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新建角色")
                }
            }
            .sheet(isPresented: $creating) {
                CharacterEditorView(app: app, character: nil)
            }
            .sheet(item: $editing) { character in
                CharacterEditorView(app: app, character: character)
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                handleImport(result)
            }
            .alert("删除角色？", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )) {
                Button("取消", role: .cancel) { pendingDelete = nil }
                Button("删除", role: .destructive) {
                    if let character = pendingDelete {
                        pendingDelete = nil
                        Task { await app.deleteCharacter(character) }
                    }
                }
            } message: {
                Text("角色和它的全部聊天记录都会删除。")
            }
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let name = url.lastPathComponent
            Task { _ = await app.importCharacter(fileName: name, data: data) }
        } catch {
            app.errorMessage = "读取文件失败：\(error.localizedDescription)"
        }
    }
}

private struct CharacterCardView: View {
    @ObservedObject var app: AppModel
    let character: CharacterSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EngineImage(client: app.client, path: "characters/\(character.avatar)")
                .frame(maxWidth: .infinity)
                .frame(height: 178)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(alignment: .topTrailing) {
                    if character.fav {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .padding(6)
                    }
                }
            Text(character.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if !character.tags.isEmpty {
                Text(character.tags.prefix(3).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(character.description.replacingOccurrences(of: "\n", with: " "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct CharacterDetailView: View {
    @ObservedObject var app: AppModel
    let character: CharacterSummary

    @Environment(\.dismiss) private var dismiss
    @State private var chats: [ChatSummary] = []
    @State private var loading = false
    @State private var editing = false
    @State private var confirmDeleteCharacter = false
    @State private var renameTarget: ChatSummary?
    @State private var renameText = ""
    @State private var deleteChatTarget: ChatSummary?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                actions
                chatSection
                details
            }
            .padding(16)
        }
        .navigationTitle(character.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: ChatTarget.self) { target in
            if let client = app.client {
                ChatView(app: app, client: client, target: target, characterAvatar: character.avatar)
            } else {
                ContentUnavailableView("引擎未就绪", systemImage: "cpu")
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        editing = true
                    } label: {
                        Label("编辑角色", systemImage: "pencil")
                    }
                    NavigationLink(value: ChatTarget(avatar: character.avatar, fileName: nil, title: character.name)) {
                        Label("开始新对话", systemImage: "plus.bubble")
                    }
                    Divider()
                    Button(role: .destructive) {
                        confirmDeleteCharacter = true
                    } label: {
                        Label("删除角色", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $editing) {
            CharacterEditorView(app: app, character: character)
        }
        .alert("删除这个角色？", isPresented: $confirmDeleteCharacter) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task {
                    await app.deleteCharacter(character)
                    dismiss()
                }
            }
        } message: {
            Text("角色卡和全部聊天都会删除，无法恢复。")
        }
        .alert("重命名聊天", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("新的名称", text: $renameText)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button("保存") {
                if let target = renameTarget {
                    renameTarget = nil
                    Task {
                        await app.renameChat(avatar: character.avatar, fileName: target.fileName, newName: renameText)
                        await loadChats()
                    }
                }
            }
        }
        .alert("删除这段聊天？", isPresented: Binding(
            get: { deleteChatTarget != nil },
            set: { if !$0 { deleteChatTarget = nil } }
        )) {
            Button("取消", role: .cancel) { deleteChatTarget = nil }
            Button("删除", role: .destructive) {
                if let target = deleteChatTarget {
                    deleteChatTarget = nil
                    Task {
                        await app.deleteChat(avatar: character.avatar, fileName: target.fileName)
                        await loadChats()
                    }
                }
            }
        } message: {
            Text(deleteChatTarget?.displayName ?? "")
        }
        .onAppear {
            Task { await loadChats() }
        }
        .refreshable { await loadChats() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            EngineImage(client: app.client, path: "characters/\(character.avatar)")
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 18))
            VStack(alignment: .leading, spacing: 6) {
                Text(character.name)
                    .font(.title2.weight(.bold))
                if !character.tags.isEmpty {
                    Text(character.tags.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(character.description.replacingOccurrences(of: "\n", with: " "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if let latest = chats.first {
                NavigationLink(value: ChatTarget(avatar: character.avatar, fileName: latest.fileName, title: character.name)) {
                    Label("继续聊天", systemImage: "bubble.left.and.bubble.right.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                NavigationLink(value: ChatTarget(avatar: character.avatar, fileName: nil, title: character.name)) {
                    Label("开始聊天", systemImage: "bubble.left.and.bubble.right.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            NavigationLink(value: ChatTarget(avatar: character.avatar, fileName: nil, title: character.name)) {
                Label("新对话", systemImage: "plus.bubble")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private var chatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("聊天记录").font(.headline)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            if chats.isEmpty {
                Text("还没有聊天。点“开始聊天”创建第一段对话。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(chats) { chat in
                    NavigationLink(value: ChatTarget(avatar: character.avatar, fileName: chat.fileName, title: character.name)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(chat.displayName)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text(chat.lastMessage.isEmpty ? chat.preview : chat.lastMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Text("\(chat.messageCount) 条消息")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            renameTarget = chat
                            renameText = chat.displayName
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            deleteChatTarget = chat
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    Divider()
                }
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !character.scenario.isEmpty {
                detailBlock("场景", character.scenario)
            }
            if !character.personality.isEmpty {
                detailBlock("性格", character.personality)
            }
            if !character.mesExample.isEmpty {
                detailBlock("对话示例", character.mesExample)
            }
            if !character.systemPrompt.isEmpty {
                detailBlock("系统提示", character.systemPrompt)
            }
        }
    }

    private func detailBlock(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text)
                .font(.footnote)
                .textSelection(.enabled)
        }
    }

    private func loadChats() async {
        loading = true
        chats = await app.chats(for: character.avatar)
        loading = false
    }
}

struct CharacterEditorView: View {
    @ObservedObject var app: AppModel
    let character: CharacterSummary?

    @Environment(\.dismiss) private var dismiss
    @State private var draft = CharacterDraft()
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名称", text: $draft.name)
                    TextField("标签（用逗号分隔）", text: $draft.tags)
                }
                Section("角色设定") {
                    editor("描述", text: $draft.description, height: 110)
                    editor("性格", text: $draft.personality, height: 70)
                    editor("场景", text: $draft.scenario, height: 70)
                }
                Section("对话") {
                    editor("开场白", text: $draft.firstMes, height: 110)
                    editor("对话示例", text: $draft.mesExample, height: 110)
                }
                Section("提示词") {
                    editor("系统提示", text: $draft.systemPrompt, height: 70)
                    editor("历史后指示", text: $draft.postHistoryInstructions, height: 70)
                }
                Section("备注") {
                    editor("作者注释", text: $draft.creatorNotes, height: 70)
                    TextField("作者", text: $draft.creator)
                    TextField("版本", text: $draft.characterVersion)
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red).font(.footnote)
                    }
                }
            }
            .navigationTitle(character == nil ? "新建角色" : "编辑角色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving { ProgressView() } else { Text("保存") }
                    }
                    .disabled(saving || !draft.isValid)
                }
            }
            .onAppear {
                if let character, draft.name.isEmpty {
                    draft = CharacterDraft(character)
                }
            }
        }
    }

    private func editor(_ title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: text)
                .frame(minHeight: height)
                .font(.body)
        }
    }

    private func save() async {
        saving = true
        error = nil
        if let character {
            let updated = await app.updateCharacter(avatar: character.avatar, draft: draft)
            if updated == nil { error = app.errorMessage }
        } else {
            let created = await app.createCharacter(draft)
            if created == nil { error = app.errorMessage }
        }
        saving = false
        if error == nil { dismiss() }
    }
}
