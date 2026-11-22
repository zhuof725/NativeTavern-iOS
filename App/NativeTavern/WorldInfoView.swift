import SwiftUI

struct WorldInfoView: View {
    @ObservedObject var app: AppModel
    @State private var creating = false
    @State private var newName = ""
    @State private var pendingDelete: WorldBookSummary?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if app.books.isEmpty {
                        Text("还没有世界书。新建一本，或在角色的嵌入世界书里使用它。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(app.books) { book in
                        NavigationLink(value: book) {
                            HStack(spacing: 10) {
                                Image(systemName: book.active ? "book.closed.fill" : "book.closed")
                                    .foregroundStyle(book.active ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(book.name)
                                    Text(book.active ? "已启用" : "未启用")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDelete = book
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                Task { await app.toggleBook(book) }
                            } label: {
                                Label(book.active ? "停用" : "启用",
                                      systemImage: book.active ? "power" : "checkmark.circle")
                            }
                            .tint(.green)
                        }
                    }
                } header: {
                    HStack {
                        Text("世界书")
                        if busy { ProgressView().controlSize(.small) }
                    }
                } footer: {
                    Text("启用的世界书会在每次生成前按关键词扫描；是否有条目进入提示词，可以在聊天的“最终提示词”里看到。")
                }
            }
            .navigationTitle("世界书")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await app.refreshBooks() }
            .navigationDestination(for: WorldBookSummary.self) { book in
                WorldInfoBookView(app: app, book: book)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newName = ""
                        creating = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新建世界书")
                }
            }
            .alert("新建世界书", isPresented: $creating) {
                TextField("名称", text: $newName)
                Button("取消", role: .cancel) {}
                Button("创建") {
                    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    Task { await create(name) }
                }
            }
            .alert("删除世界书？", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )) {
                Button("取消", role: .cancel) { pendingDelete = nil }
                Button("删除", role: .destructive) {
                    if let book = pendingDelete {
                        pendingDelete = nil
                        Task { await app.deleteBook(book) }
                    }
                }
            } message: {
                Text(pendingDelete?.name ?? "")
            }
        }
    }

    private func create(_ name: String) async {
        guard let client = app.client else { return }
        busy = true
        do {
            struct Created: Decodable { let name: String }
            _ = try await client.call(
                "worldinfo.create",
                args: ["name": .string(name), "entries": .object([:])],
                as: Created.self
            )
            await app.refreshBooks()
        } catch {
            app.errorMessage = "创建世界书失败：\(error.localizedDescription)"
        }
        busy = false
    }
}

struct WorldInfoBookView: View {
    @ObservedObject var app: AppModel
    let book: WorldBookSummary

    @State private var entries: [WorldInfoEntry] = []
    @State private var loading = false
    @State private var editingEntry: WorldInfoEntry?
    @State private var creatingEntry = false
    @State private var pendingDelete: WorldInfoEntry?
    @State private var active: Bool

    init(app: AppModel, book: WorldBookSummary) {
        self.app = app
        self.book = book
        _active = State(initialValue: book.active)
    }

    var body: some View {
        List {
            Section {
                Toggle("生成时启用", isOn: Binding(
                    get: { active },
                    set: { value in
                        active = value
                        Task {
                            await app.toggleBook(WorldBookSummary(name: book.name, active: !value))
                        }
                    }
                ))
            } footer: {
                Text("启用状态与酒馆里的世界书开关一致。")
            }
            Section("条目（\(entries.count)）") {
                if loading && entries.isEmpty {
                    HStack { ProgressView(); Text("读取中…") }
                }
                ForEach(entries) { entry in
                    Button {
                        editingEntry = entry
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Spacer()
                                if entry.constant == true {
                                    Text("常驻")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if entry.disable == true {
                                    Text("停用")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            if !entry.keysText.isEmpty {
                                Text(entry.keysText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.content ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            pendingDelete = entry
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle(book.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    creatingEntry = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新增条目")
            }
        }
        .sheet(item: $editingEntry, onDismiss: { Task { await load() } }) { entry in
            WorldInfoEntryEditor(app: app, book: book.name, entry: entry)
        }
        .sheet(isPresented: $creatingEntry, onDismiss: { Task { await load() } }) {
            WorldInfoEntryEditor(app: app, book: book.name, entry: nil)
        }
        .alert("删除条目？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let entry = pendingDelete {
                    pendingDelete = nil
                    Task { await delete(entry) }
                }
            }
        } message: {
            Text(pendingDelete?.title ?? "")
        }
        .task { await load() }
    }

    private func load() async {
        guard let client = app.client else { return }
        loading = true
        do {
            let detail = try await client.call(
                "worldinfo.get",
                args: ["name": .string(book.name)],
                as: WorldInfoBook.self
            )
            let values = detail.data?.entries?.values.map { $0 } ?? []
            entries = values.sorted { lhs, rhs in
                if (lhs.order ?? 100) != (rhs.order ?? 100) {
                    return (lhs.order ?? 100) < (rhs.order ?? 100)
                }
                return lhs.uid < rhs.uid
            }
        } catch {
            app.errorMessage = "读取条目失败：\(error.localizedDescription)"
        }
        loading = false
    }

    private func delete(_ entry: WorldInfoEntry) async {
        guard let client = app.client else { return }
        do {
            struct Deleted: Decodable { let deleted: Int }
            _ = try await client.call(
                "worldinfo.deleteEntry",
                args: ["book": .string(book.name), "uid": .number(Double(entry.uid))],
                as: Deleted.self
            )
            await load()
        } catch {
            app.errorMessage = "删除条目失败：\(error.localizedDescription)"
        }
    }
}

struct WorldInfoEntryEditor: View {
    @ObservedObject var app: AppModel
    let book: String
    let entry: WorldInfoEntry?

    @Environment(\.dismiss) private var dismiss
    @State private var comment = ""
    @State private var keys = ""
    @State private var secondary = ""
    @State private var content = ""
    @State private var constant = false
    @State private var selective = false
    @State private var disabled = false
    @State private var useRegex = false
    @State private var order = 100
    @State private var position = 0
    @State private var depth = 4
    @State private var probability = 100
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("内容") {
                    TextField("备注 / 标题", text: $comment)
                    TextField("关键词（逗号分隔）", text: $keys)
                        .textInputAutocapitalization(.never)
                    TextField("次关键词（逗号分隔）", text: $secondary)
                        .textInputAutocapitalization(.never)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("条目内容").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $content).frame(minHeight: 140)
                    }
                }
                Section("触发规则") {
                    Toggle("常驻（无需关键词）", isOn: $constant)
                    Toggle("选择性匹配次关键词", isOn: $selective)
                    Toggle("停用此条目", isOn: $disabled)
                    Toggle("按正则解释关键词", isOn: $useRegex)
                }
                Section("插入位置") {
                    Picker("位置", selection: $position) {
                        Text("角色定义之前").tag(0)
                        Text("角色定义之后").tag(1)
                        Text("对话示例之前").tag(2)
                        Text("对话示例之后").tag(3)
                        Text("按深度插入").tag(4)
                    }
                    Stepper("顺序：\(order)", value: $order, in: 0...1000)
                    if position == 4 {
                        Stepper("深度：\(depth)", value: $depth, in: 0...50)
                    }
                    Stepper("触发概率：\(probability)%", value: $probability, in: 0...100)
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red).font(.footnote)
                    }
                }
            }
            .navigationTitle(entry == nil ? "新增条目" : "编辑条目")
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
                    .disabled(saving || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear(perform: loadDraft)
        }
    }

    private func loadDraft() {
        guard let entry else { return }
        comment = entry.comment ?? ""
        keys = (entry.key ?? []).joined(separator: ", ")
        secondary = (entry.keysecondary ?? []).joined(separator: ", ")
        content = entry.content ?? ""
        constant = entry.constant ?? false
        selective = entry.selective ?? false
        disabled = entry.disable ?? false
        useRegex = entry.useRegex ?? false
        order = entry.order ?? 100
        position = entry.position ?? 0
        depth = entry.depth ?? 4
        probability = entry.probability ?? 100
    }

    private func save() async {
        guard let client = app.client else { return }
        saving = true
        error = nil
        var payload: [String: JSONValue] = [
            "comment": .string(comment),
            "key": .array(split(keys).map { .string($0) }),
            "keysecondary": .array(split(secondary).map { .string($0) }),
            "content": .string(content),
            "constant": .bool(constant),
            "selective": .bool(selective),
            "disable": .bool(disabled),
            "useRegex": .bool(useRegex),
            "order": .number(Double(order)),
            "position": .number(Double(position)),
            "depth": .number(Double(depth)),
            "probability": .number(Double(probability)),
            "useProbability": .bool(probability < 100),
        ]
        if let entry {
            payload["uid"] = .number(Double(entry.uid))
        }
        do {
            _ = try await client.call(
                "worldinfo.saveEntry",
                args: ["book": .string(book), "entry": .object(payload)],
                as: WorldInfoEntryReply.self
            )
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        saving = false
    }

    private func split(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
