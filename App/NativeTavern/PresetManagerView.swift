import SwiftUI

/// Chat-completion presets, prompt order, and the other preset kinds the tavern
/// keeps (instruct, context template, system prompt, reasoning).
struct PresetManagerView: View {
    @ObservedObject var app: AppModel

    @State private var kinds: [PresetKind] = []
    @State private var current = ""
    @State private var loading = false
    @State private var creating = false
    @State private var newName = ""
    @State private var pendingDelete: PresetRef?

    struct PresetKind: Identifiable, Hashable {
        let kind: String
        let names: [String]
        var id: String { kind }

        var label: String {
            switch kind {
            case "openai": return "对话补全"
            case "instruct": return "指令模式"
            case "context": return "上下文模板"
            case "sysprompt": return "系统提示词"
            case "reasoning": return "推理格式"
            case "textgen": return "文本补全"
            default: return kind
            }
        }
    }

    struct PresetRef: Identifiable, Hashable {
        let kind: String
        let name: String
        var id: String { "\(kind)/\(name)" }
    }

    struct KindsReply: Decodable {
        let kinds: [PresetKind]
        let current: String
    }

    var body: some View {
        List {
            ForEach(kinds.filter { !$0.names.isEmpty }) { entry in
                Section {
                    ForEach(entry.names, id: \.self) { name in
                        NavigationLink {
                            PresetDetailView(app: app, kind: entry.kind, name: name) {
                                Task { await load() }
                            }
                        } label: {
                            HStack {
                                Text(name)
                                if entry.kind == "openai" && name == current {
                                    Spacer()
                                    Text("当前")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.16), in: Capsule())
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .contextMenu {
                            if entry.kind == "openai" {
                                Button {
                                    Task { await apply(name) }
                                } label: {
                                    Label("应用这个预设", systemImage: "checkmark.circle")
                                }
                                Button {
                                    Task { await duplicate(name) }
                                } label: {
                                    Label("复制副本", systemImage: "plus.square.on.square")
                                }
                            }
                            if entry.kind != "openai" {
                                Button(role: .destructive) {
                                    pendingDelete = PresetRef(kind: entry.kind, name: name)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(entry.label)
                        Spacer()
                        Text("\(entry.names.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                NavigationLink {
                    PromptListView(app: app)
                } label: {
                    Label("提示词顺序与开关", systemImage: "list.number")
                }
            }
        }
        .navigationTitle("对话补全预设")
        .refreshable { await load() }
        .overlay {
            if kinds.isEmpty && !loading {
                ProgressView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        newName = "我的预设"
                        creating = true
                    } label: {
                        Label("新建对话补全预设", systemImage: "plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("新建预设", isPresented: $creating) {
            TextField("名称", text: $newName)
            Button("取消", role: .cancel) {}
            Button("创建") {
                Task { await create() }
            }
        } message: {
            Text("会以当前生效的参数为副本。")
        }
        .alert("删除预设？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let ref = pendingDelete {
                    pendingDelete = nil
                    Task { await delete(ref) }
                }
            }
        } message: {
            Text(pendingDelete?.name ?? "")
        }
        .task { await load() }
    }

    private func load() async {
        guard let client = app.client else { return }
        loading = true
        do {
            let reply = try await client.call("preset.kinds", as: KindsReply.self)
            kinds = reply.kinds
            current = reply.current
        } catch {
            app.errorMessage = "预设读取失败：\(error.localizedDescription)"
        }
        loading = false
    }

    private func apply(_ name: String) async {
        guard let client = app.client else { return }
        struct Applied: Decodable { let applied: String }
        _ = try? await client.call("preset.apply", args: ["name": .string(name)], as: Applied.self)
        await app.refreshSettings()
        await app.refreshPresets()
        await load()
    }

    private func duplicate(_ name: String) async {
        guard let client = app.client else { return }
        struct Saved: Decodable { let name: String }
        _ = try? await client.call(
            "preset.duplicate",
            args: ["kind": .string("openai"), "name": .string(name), "newName": .string("\(name) 副本")],
            as: Saved.self
        )
        await load()
    }

    private func create() async {
        guard let client = app.client else { return }
        struct Saved: Decodable { let name: String }
        _ = try? await client.call(
            "preset.duplicate",
            args: [
                "kind": .string("openai"),
                "name": .string(current.isEmpty ? "Default" : current),
                "newName": .string(newName),
            ],
            as: Saved.self
        )
        await load()
    }

    private func delete(_ ref: PresetRef) async {
        guard let client = app.client else { return }
        struct Deleted: Decodable { let deleted: String }
        _ = try? await client.call(
            "preset.delete",
            args: ["kind": .string(ref.kind), "name": .string(ref.name)],
            as: Deleted.self
        )
        await load()
    }
}

/// One preset: its parameters, editable when the kind allows it, with a reset
/// to the shipped default.
struct PresetDetailView: View {
    @ObservedObject var app: AppModel
    let kind: String
    let name: String
    var onChanged: (() -> Void)?

    @State private var fields: [(key: String, value: String)] = []
    @State private var raw: [String: JSONValue] = [:]
    @State private var editing = false
    @State private var edited: [String: String] = [:]
    @State private var saving = false
    @State private var error: String?

    struct Detail: Decodable {
        let kind: String
        let name: String
        let editable: Bool
    }

    var body: some View {
        List {
            Section {
                ForEach(fields, id: \.key) { field in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(field.key).font(.caption).foregroundStyle(.secondary)
                        if editing, let binding = bindingFor(field.key) {
                            TextEditor(text: binding)
                                .frame(minHeight: 44)
                                .font(.footnote.monospaced())
                        } else {
                            Text(field.value)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            } header: {
                Text("参数（\(fields.count)）")
            } footer: {
                if editing {
                    Text("只提交改动过的键；其余保持原样。")
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if kind == "openai" {
                        Button {
                            Task { await apply() }
                        } label: {
                            Label("应用", systemImage: "checkmark.circle")
                        }
                    }
                    Button {
                        preparedEdit()
                    } label: {
                        Label(editing ? "正在编辑" : "编辑参数", systemImage: "pencil")
                    }
                    .disabled(editing)
                    if editing {
                        Button {
                            Task { await save() }
                        } label: {
                            Label("保存", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            editing = false
                            edited = [:]
                        } label: {
                            Label("取消编辑", systemImage: "xmark")
                        }
                    }
                    Button {
                        Task { await restore() }
                    } label: {
                        Label("恢复默认", systemImage: "arrow.uturn.backward")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task { await load() }
    }

    private func bindingFor(_ key: String) -> Binding<String>? {
        guard editing else { return nil }
        return Binding(
            get: { edited[key] ?? fields.first { $0.key == key }?.value ?? "" },
            set: { edited[key] = $0 }
        )
    }

    private func preparedEdit() {
        edited = [:]
        editing = true
    }

    private func load() async {
        guard let client = app.client else { return }
        do {
            let reply = try await client.call(
                "preset.detail",
                args: ["kind": .string(kind), "name": .string(name)],
                as: PresetDetailReply.self
            )
            raw = reply.preset
            fields = reply.preset.map { (key, value) in
                (key, Self.describe(value))
            }.sorted { $0.key < $1.key }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Presents a JSON value the way the tavern's own preset list does: strings
    /// unquoted, scalars as text, nested structures as compact JSON.
    private static func describe(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): return text
        case .number(let number):
            return number == number.rounded() ? String(Int(number)) : String(number)
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        case .array, .object:
            guard let data = try? JSONEncoder().encode(value),
                  let text = String(data: data, encoding: .utf8) else { return "" }
            return text
        }
    }

    private func save() async {
        guard let client = app.client, !edited.isEmpty else {
            editing = false
            return
        }
        saving = true
        error = nil
        var preset = raw
        for (key, text) in edited {
            preset[key] = Self.parse(text, original: raw[key])
        }
        do {
            struct Saved: Decodable { let name: String }
            _ = try await client.call(
                "preset.save",
                args: ["kind": .string(kind), "name": .string(name), "preset": .object(preset)],
                as: Saved.self
            )
            editing = false
            edited = [:]
            await load()
            onChanged?()
        } catch {
            self.error = error.localizedDescription
        }
        saving = false
    }

    /// Edits keep the original JSON type, so a number stays a number.
    private static func parse(_ text: String, original: JSONValue?) -> JSONValue {
        switch original {
        case .number:
            if let value = Double(text.trimmingCharacters(in: .whitespaces)) { return .number(value) }
        case .bool:
            return .bool(text.trimmingCharacters(in: .whitespaces).lowercased() == "true")
        case .null:
            if text.trimmingCharacters(in: .whitespaces) == "null" { return .null }
        case .array, .object:
            if let data = text.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) {
                return decoded
            }
        default:
            break
        }
        return .string(text)
    }

    private func apply() async {
        guard let client = app.client else { return }
        struct Applied: Decodable { let applied: String }
        _ = try? await client.call("preset.apply", args: ["name": .string(name)], as: Applied.self)
        await app.refreshSettings()
        onChanged?()
    }

    private func restore() async {
        guard let client = app.client else { return }
        struct Restored: Decodable { let restored: Bool }
        _ = try? await client.call(
            "preset.restore",
            args: ["kind": .string(kind), "name": .string(name)],
            as: Restored.self
        )
        await load()
        onChanged?()
    }
}

/// `preset.detail` returns the preset as free-form JSON, so it is decoded
/// through a JSONValue that can also read.
struct PresetDetailReply: Decodable {
    let kind: String
    let name: String
    let preset: [String: JSONValue]
}

extension JSONValue: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }
}
