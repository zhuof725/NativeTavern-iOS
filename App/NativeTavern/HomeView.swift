import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CharacterRow: Identifiable, Hashable {
    let character: CharacterSummary
    let chat: ChatSummary?

    var id: String { character.avatar }
}

/// Home: characters on the left, the selected conversation on the right, in the
/// style of the Apple Glass reference (list column + reading column).
struct HomeView: View {
    @ObservedObject var app: AppModel

    @State private var characters: [CharacterSummary] = []
    @State private var chatsByAvatar: [String: ChatSummary] = [:]
    @State private var selectedAvatar: String?
    @State private var query = ""
    @State private var creating = false
    @State private var editing: CharacterSummary?
    @State private var importing = false
    @State private var pendingDelete: CharacterSummary?
    @State private var reloadToken = 0

    private var rows: [CharacterRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return characters
            .filter { needle.isEmpty || $0.name.lowercased().contains(needle) || $0.description.lowercased().contains(needle) }
            .map { CharacterRow(character: $0, chat: chatsByAvatar[$0.avatar]) }
    }

    private var current: CharacterRow? {
        guard let selectedAvatar else { return rows.first }
        return rows.first { $0.character.avatar == selectedAvatar } ?? rows.first
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: min(340, max(272, geometry.size.width * 0.34)))
                    Rectangle().fill(Glass.hairline).frame(width: 0.5)
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color.black.opacity(0.12))
            .navigationTitle("角色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { importing = true } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .accessibilityLabel("导入角色卡")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { creating = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新建角色")
                }
            }
            .sheet(isPresented: $creating) {
                CharacterEditorView(app: app, character: nil) {
                    Task { await reload() }
                }
            }
            .sheet(item: $editing) { character in
                CharacterEditorView(app: app, character: character) {
                    Task { await reload() }
                }
            }
            .importPicker($importing, kind: .character) { urls in
                Task { await importFiles(urls) }
            }
            .alert("删除角色？", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )) {
                Button("取消", role: .cancel) { pendingDelete = nil }
                Button("删除", role: .destructive) {
                    if let character = pendingDelete {
                        pendingDelete = nil
                        Task {
                            await app.deleteCharacter(character)
                            await reload()
                        }
                    }
                }
            } message: {
                Text("角色和它的全部聊天记录都会删除。")
            }
            .task { await reload() }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 10) {
            searchField
            ScrollView {
                LazyVStack(spacing: 2) {
                    if rows.isEmpty {
                        Text(characters.isEmpty ? "还没有角色" : "没有匹配的角色")
                            .font(.footnote)
                            .foregroundStyle(Glass.label3)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(rows) { row in
                        SidebarRow(
                            app: app,
                            row: row,
                            isSelected: current?.id == row.id
                        )
                        .onTapGesture { selectedAvatar = row.character.avatar }
                        .contextMenu {
                            Button { editing = row.character } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                pendingDelete = row.character
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.hidden)
            .refreshable { await reload() }
        }
        .padding(.top, 8)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.footnote)
                .foregroundStyle(Glass.label3)
            TextField("搜索角色", text: $query)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Glass.label3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Glass.float, in: Capsule())
        .overlay { Capsule().strokeBorder(Glass.hairline, lineWidth: 0.5) }
        .padding(.horizontal, 12)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let row = current, let client = app.client {
            ChatView(
                app: app,
                client: client,
                target: ChatTarget(
                    avatar: row.character.avatar,
                    fileName: row.chat?.fileName,
                    title: row.character.name
                ),
                characterAvatar: row.character.avatar,
                reloadToken: reloadToken
            )
            .id("\(row.character.avatar)-\(row.chat?.fileName ?? "new")-\(reloadToken)")
        } else {
            ContentUnavailableView("选择一个角色", systemImage: "person.2")
        }
    }

    // MARK: Data

    private func reload() async {
        if app.characters.isEmpty {
            await app.refreshCharacters()
        }
        characters = app.characters
        var latest: [String: ChatSummary] = [:]
        for character in characters.prefix(60) {
            if let chat = await app.chats(for: character.avatar).first {
                latest[character.avatar] = chat
            }
        }
        chatsByAvatar = latest
        if selectedAvatar == nil {
            selectedAvatar = characters.first?.avatar
        }
        reloadToken += 1
    }

    /// Reads the picked files and hands them to the core's own card importers.
    /// The picker's security scope is only valid while the URL is accessed, so
    /// each file is copied into memory here and the scope released immediately.
    private func importFiles(_ urls: [URL]) async {
        var failures: [String] = []
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                failures.append("\(url.lastPathComponent)：无法读取")
                continue
            }
            let name = url.lastPathComponent
            if let created = await app.importCharacter(fileName: name, data: data) {
                selectedAvatar = created.avatar
            } else {
                failures.append("\(name)：\(app.errorMessage ?? "解析失败")")
            }
        }
        if !failures.isEmpty {
            app.errorMessage = "部分文件没有导入成功：\n" + failures.joined(separator: "\n")
        }
        await reload()
    }
}
