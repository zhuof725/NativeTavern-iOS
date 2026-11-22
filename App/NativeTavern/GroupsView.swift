import SwiftUI

// MARK: - Types

struct GroupSummary: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let members: [String]
    let disabledMembers: [String]
    let avatar: String
    let chatId: String
    let chats: [String]
    let activationStrategy: Int
    let generationMode: Int
    let autoModeDelay: Int
    let allowSelfResponses: Bool
    let fav: Bool
    let lastChat: Double

    var enabledMembers: [String] { members.filter { !disabledMembers.contains($0) } }
}

struct GroupListReply: Decodable { let groups: [GroupSummary] }
struct GroupReply: Decodable { let group: GroupSummary }
struct GroupDeleted: Decodable { let deleted: String }

struct GroupChatInfo: Decodable, Identifiable, Hashable {
    let id: String
    let messageCount: Int
    let preview: String
    let lastMessage: String
    let lastUpdated: String

    var displayName: String { id }
}

struct GroupChatListReply: Decodable {
    let chats: [GroupChatInfo]
    let current: String
}

struct GroupSnapshot: Decodable {
    let messages: [ChatMessage]
    let fileName: String?
    let characterName: String?
    let userName: String?
    let groupId: String?
    let groupName: String?
    let chatId: String?
    let error: String?
}

/// Activation strategies and generation modes, as upstream numbers them.
enum GroupOptions {
    static let strategies = ["自然", "列表顺序", "手动", "轮询"]
    static let modes = ["交换角色", "追加回复"]
}

// MARK: - List

struct GroupsView: View {
    @ObservedObject var app: AppModel

    @State private var groups: [GroupSummary] = []
    @State private var loading = false
    @State private var editing: GroupSummary?
    @State private var creating = false
    @State private var pendingDelete: GroupSummary?

    var body: some View {
        List {
            if groups.isEmpty && !loading {
                Section {
                    Text("还没有群聊。群聊让多个角色在同一个对话里轮流回复。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(groups) { group in
                NavigationLink {
                    GroupChatView(app: app, group: group) {
                        Task { await load() }
                    }
                } label: {
                    HStack(spacing: 10) {
                        GroupAvatar(app: app, group: group)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(group.name).font(.subheadline.weight(.semibold))
                                if group.fav {
                                    Image(systemName: "star.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.yellow)
                                }
                            }
                            Text("\(group.enabledMembers.count) 位成员 · \(GroupOptions.strategies[min(group.activationStrategy, GroupOptions.strategies.count - 1)])")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .contextMenu {
                    Button { editing = group } label: { Label("编辑群聊", systemImage: "pencil") }
                    Button {
                        Task { await toggleFavourite(group) }
                    } label: {
                        Label(group.fav ? "取消收藏" : "收藏", systemImage: group.fav ? "star.slash" : "star")
                    }
                    Divider()
                    Button(role: .destructive) { pendingDelete = group } label: {
                        Label("删除群聊", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("群聊")
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { creating = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("新建群聊")
            }
        }
        .sheet(isPresented: $creating, onDismiss: { Task { await load() } }) {
            GroupEditorView(app: app, group: nil)
        }
        .sheet(item: $editing, onDismiss: { Task { await load() } }) { group in
            GroupEditorView(app: app, group: group)
        }
        .alert("删除群聊？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let group = pendingDelete {
                    pendingDelete = nil
                    Task { await delete(group) }
                }
            }
        } message: {
            Text("群聊和它的全部聊天记录都会删除。")
        }
        .task { await load() }
    }

    private func load() async {
        guard let client = app.client else { return }
        loading = true
        do {
            let reply = try await client.call("group.list", as: GroupListReply.self)
            groups = reply.groups.sorted { $0.lastChat > $1.lastChat }
        } catch {
            app.errorMessage = "群聊列表读取失败：\(error.localizedDescription)"
        }
        loading = false
    }

    private func toggleFavourite(_ group: GroupSummary) async {
        guard let client = app.client else { return }
        struct Edited: Decodable { let group: GroupSummary }
        _ = try? await client.call(
            "group.edit",
            args: ["id": .string(group.id), "patch": .object(["fav": .bool(!group.fav)])],
            as: Edited.self
        )
        await load()
    }

    private func delete(_ group: GroupSummary) async {
        guard let client = app.client else { return }
        _ = try? await client.call("group.delete", args: ["id": .string(group.id)], as: GroupDeleted.self)
        await load()
    }
}

/// A group's avatar is an uploaded image; without one, the members' faces are
/// stacked so a new group is still recognisable.
struct GroupAvatar: View {
    @ObservedObject var app: AppModel
    let group: GroupSummary

    var body: some View {
        if !group.avatar.isEmpty {
            EngineImage(client: app.client, path: "characters/\(group.avatar)")
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.18))
                Image(systemName: "person.3.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Editor

struct GroupEditorView: View {
    @ObservedObject var app: AppModel
    let group: GroupSummary?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var members: Set<String> = []
    @State private var disabled: Set<String> = []
    @State private var strategy = 0
    @State private var mode = 0
    @State private var autoDelay = 5
    @State private var allowSelf = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("群聊名称", text: $name)
                }
                Section {
                    ForEach(app.characters) { character in
                        let enabled = members.contains(character.avatar)
                        Button {
                            if enabled { members.remove(character.avatar) } else { members.insert(character.avatar) }
                        } label: {
                            HStack(spacing: 10) {
                                EngineImage(client: app.client, path: "characters/\(character.avatar)")
                                    .frame(width: 32, height: 32)
                                    .clipShape(Circle())
                                Text(character.name).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("成员（\(members.count)）")
                } footer: {
                    Text("顺序即列表顺序策略下的发言顺序，可在聊天页调整。")
                }
                if !disabled.isEmpty {
                    Section("已静音") {
                        ForEach(Array(disabled), id: \.self) { avatar in
                            HStack {
                                Text(app.character(avatar: avatar)?.name ?? avatar)
                                Spacer()
                                Button("取消静音") { disabled.remove(avatar) }
                                    .font(.caption)
                            }
                        }
                    }
                }
                Section("生成") {
                    Picker("发言策略", selection: $strategy) {
                        ForEach(Array(GroupOptions.strategies.enumerated()), id: \.offset) { index, label in
                            Text(label).tag(index)
                        }
                    }
                    Picker("生成模式", selection: $mode) {
                        ForEach(Array(GroupOptions.modes.enumerated()), id: \.offset) { index, label in
                            Text(label).tag(index)
                        }
                    }
                    Stepper("自动模式间隔：\(autoDelay) 秒", value: $autoDelay, in: 1...60)
                    Toggle("允许角色自我回应", isOn: $allowSelf)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle(group == nil ? "新建群聊" : "编辑群聊")
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
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty || members.isEmpty)
                }
            }
            .onAppear(perform: loadDraft)
        }
    }

    private func loadDraft() {
        guard let group else { return }
        name = group.name
        members = Set(group.members)
        disabled = Set(group.disabledMembers)
        strategy = group.activationStrategy
        mode = group.generationMode
        autoDelay = group.autoModeDelay
        allowSelf = group.allowSelfResponses
    }

    private func save() async {
        guard let client = app.client else { return }
        saving = true
        error = nil
        do {
            if let group {
                // Member order is meaningful for the list strategy, so the
                // current order is preserved and new picks are appended.
                let ordered = group.members.filter { members.contains($0) }
                    + members.subtracting(group.members).sorted()
                let patch: [String: JSONValue] = [
                    "name": .string(name),
                    "members": .array(ordered.map { .string($0) }),
                    "disabled_members": .array(disabled.map { .string($0) }),
                    "activation_strategy": .number(Double(strategy)),
                    "generation_mode": .number(Double(mode)),
                    "auto_mode_delay": .number(Double(autoDelay)),
                    "allow_self_responses": .bool(allowSelf),
                ]
                _ = try await client.call(
                    "group.edit",
                    args: ["id": .string(group.id), "patch": .object(patch)],
                    as: GroupReply.self
                )
            } else {
                _ = try await client.call(
                    "group.create",
                    args: [
                        "name": .string(name),
                        "members": .array(members.sorted().map { .string($0) }),
                        "activationStrategy": .number(Double(strategy)),
                        "generationMode": .number(Double(mode)),
                        "allowSelfResponses": .bool(allowSelf),
                    ],
                    as: GroupReply.self
                )
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        saving = false
    }
}
