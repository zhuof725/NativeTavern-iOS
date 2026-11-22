import SwiftUI
import UIKit

/// The settings screen: a search field, the current persona, and grouped rows
/// that lead to each area — the layout of the reference screenshots.
struct SettingsHomeView: View {
    @ObservedObject var app: AppModel

    @State private var query = ""
    @State private var personas: [PersonaSummary] = []
    @State private var personaPicker = false

    var body: some View {
        List {
            if query.isEmpty {
                Section {
                    Button {
                        Task { await loadPersonas() }
                        personaPicker = true
                    } label: {
                        HStack(spacing: 12) {
                            EngineImage(client: app.client, path: "User Avatars/\(app.settings?.userAvatar ?? "user-default.png")")
                                .frame(width: 52, height: 52)
                                .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.settings?.userName ?? "User")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("当前人设")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }

            ForEach(sections.filter { !$0.rows.filter(matches).isEmpty }, id: \.id) { section in
                Section {
                    ForEach(section.rows.filter(matches)) { row in
                        NavigationLink {
                            destination(for: row)
                        } label: {
                            SettingsRow(app: app, row: row)
                        }
                    }
                }
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, prompt: "搜索设置")
        .refreshable {
            await app.refreshSettings()
            await loadPersonas()
        }
        .sheet(isPresented: $personaPicker) {
            NavigationStack {
                List {
                    ForEach(personas) { persona in
                        Button {
                            personaPicker = false
                            Task { await app.selectPersona(persona) }
                        } label: {
                            HStack(spacing: 12) {
                                EngineImage(client: app.client, path: "User Avatars/\(persona.avatar)")
                                    .frame(width: 36, height: 36)
                                    .clipShape(Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(persona.name).foregroundStyle(.primary)
                                    if !persona.title.isEmpty {
                                        Text(persona.title).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if persona.current {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .overlay {
                    if personas.isEmpty {
                        ContentUnavailableView("还没有人设", systemImage: "person.crop.circle",
                                               description: Text("在“人设”页导入一张图片即可创建。"))
                    }
                }
                .navigationTitle("选择人设")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { personaPicker = false }
                    }
                }
            }
        }
        .task {
            await app.refreshSettings()
            await loadPersonas()
        }
    }

    private func matches(_ row: SettingsRow.Model) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return row.title.localizedCaseInsensitiveContains(needle)
            || (row.detail?.localizedCaseInsensitiveContains(needle) ?? false)
    }

    private func loadPersonas() async {
        guard let client = app.client else { return }
        if let reply = try? await client.call("persona.list", as: PersonaListReply.self) {
            personas = reply.personas
        }
    }

    @ViewBuilder
    private func destination(for row: SettingsRow.Model) -> some View {
        switch row.id {
        case "connection": ConnectionSettingsView(app: app)
        case "generation": GenerationSettingsView(app: app)
        case "prompt": PresetManagerView(app: app)
        case "worldinfo": WorldInfoView(app: app)
        case "persona": PersonaSettingsView(app: app)
        case "background": BackgroundSettingsView(app: app)
        case "appearance": AppearanceSettingsView(app: app)
        case "general": GeneralSettingsView(app: app)
        case "extensions": ExtensionsView(app: app)
        case "engine": EngineSettingsView(app: app)
        default: AboutView(app: app)
        }
    }

    // MARK: Sections

    private var sections: [SettingsRow.Section] {
        let settings = app.settings
        return [
            SettingsRow.Section(id: "model", rows: [
                .init(id: "connection", title: "连接", symbol: "powerplug.fill",
                      tint: .green, detail: providerLabel(settings?.source)),
                .init(id: "generation", title: "生成参数", symbol: "slider.horizontal.3",
                      tint: .blue, detail: nil),
                .init(id: "prompt", title: "提示词与格式", symbol: "text.justify.left",
                      tint: .indigo, detail: nil),
            ]),
            SettingsRow.Section(id: "content", rows: [
                .init(id: "worldinfo", title: "世界书", symbol: "book.closed.fill",
                      tint: .orange, detail: nil),
                .init(id: "persona", title: "人设", symbol: "person.crop.square.fill",
                      tint: .pink, detail: nil),
                .init(id: "background", title: "背景", symbol: "photo.fill",
                      tint: .teal, detail: nil),
            ]),
            SettingsRow.Section(id: "app", rows: [
                .init(id: "appearance", title: "外观", symbol: "paintpalette.fill",
                      tint: .purple, detail: nil),
                .init(id: "general", title: "通用", symbol: "gearshape.fill",
                      tint: .gray, detail: nil),
                .init(id: "extensions", title: "扩展", symbol: "puzzlepiece.extension.fill",
                      tint: .red, detail: nil),
                .init(id: "engine", title: "本地引擎", symbol: "cpu.fill",
                      tint: .gray, detail: nil),
            ]),
            SettingsRow.Section(id: "about", rows: [
                .init(id: "about", title: "关于", symbol: "info.circle.fill",
                      tint: .gray, detail: "1.19.0"),
            ]),
        ]
    }

    private func providerLabel(_ source: String?) -> String? {
        guard let source, !source.isEmpty else { return nil }
        let names: [String: String] = [
            "openai": "OpenAI", "custom": "自定义", "claude": "Claude",
            "openrouter": "OpenRouter", "deepseek": "DeepSeek", "groq": "Groq",
            "mistralai": "Mistral", "makersuite": "Google AI Studio",
            "xai": "xAI", "zai": "Z.AI", "perplexity": "Perplexity", "cohere": "Cohere",
        ]
        return names[source] ?? source
    }
}

/// One row: coloured glyph, title, optional trailing detail.
struct SettingsRow: View {
    struct Model: Identifiable, Hashable {
        let id: String
        let title: String
        let symbol: String
        let tint: Color
        let detail: String?
    }

    struct Section: Identifiable {
        let id: String
        let rows: [Model]
    }

    @ObservedObject var app: AppModel
    let row: Model

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(row.tint.gradient)
                .frame(width: 29, height: 29)
                .overlay {
                    Image(systemName: row.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
            Text(row.title)
            Spacer()
            if let detail = row.detail, !detail.isEmpty {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
