import SwiftUI
import Foundation

/// 人设: the persona list with its avatar, plus import.
struct PersonaSettingsView: View {
    @ObservedObject var app: AppModel

    @State private var personas: [PersonaSummary] = []
    @State private var notice: String?
    @State private var loading = false

    var body: some View {
        List {
            Section {
                ForEach(personas) { persona in
                    Button {
                        Task {
                            await app.selectPersona(persona)
                            await load()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            EngineImage(client: app.client, path: "User Avatars/\(persona.avatar)")
                                .frame(width: 44, height: 44)
                                .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(persona.name).foregroundStyle(.primary)
                                if !persona.description.isEmpty {
                                    Text(persona.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
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
            } footer: {
                if let notice {
                    Text(notice)
                } else {
                    Text("点一下切换发话人设；人设名称就是你在聊天里显示的名字。")
                }
            }

            Section {
                Button {
                    pickImage()
                } label: {
                    Label("导入人设图片", systemImage: "person.crop.circle.badge.plus")
                }
            }
        }
        .navigationTitle("人设")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let client = app.client else { return }
        loading = true
        if let reply = try? await client.call("persona.list", as: PersonaListReply.self) {
            personas = reply.personas
        }
        loading = false
    }

    private func pickImage() {
        DocumentPickerPresenter.present(
            configuration: .init(types: ImportTypes.personaImage, allowsMultiple: false),
            onPick: { files in
                Task { await importImage(files) }
            },
            onFailure: { message in notice = message }
        )
    }

    private func importImage(_ files: [PickedFile]) async {
        guard let client = app.client, let file = files.first else { return }
        struct Stored: Decodable { let avatar: String; let name: String }
        do {
            let stored = try await client.call(
                "persona.upload",
                args: [
                    "fileName": .string(file.name),
                    "name": .string((file.name as NSString).deletingPathExtension),
                    "data": .string(file.data.base64EncodedString()),
                ],
                as: Stored.self
            )
            notice = "已添加人设 \(stored.name)"
            await load()
        } catch {
            notice = "导入失败：\(error.localizedDescription)"
        }
    }
}

/// 背景: the images the tavern can show behind the chat.
struct BackgroundSettingsView: View {
    @ObservedObject var app: AppModel

    @State private var backgrounds: [BackgroundSummary] = []
    @State private var notice: String?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                Button {
                    Task { await select("") }
                } label: {
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.secondary.opacity(0.12))
                            .frame(height: 78)
                            .overlay {
                                Image(systemName: "slash.circle")
                                    .foregroundStyle(.secondary)
                            }
                        Text("无背景").font(.caption2)
                    }
                }
                .buttonStyle(.plain)

                ForEach(backgrounds) { background in
                    Button {
                        Task { await select(background.filename) }
                    } label: {
                        VStack(spacing: 6) {
                            EngineImage(client: app.client, path: "backgrounds/\(background.filename)")
                                .frame(height: 78)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(background.current ? Color.accentColor : Color.clear, lineWidth: 2)
                                }
                            Text(background.displayName)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
        }
        .overlay {
            if backgrounds.isEmpty {
                ContentUnavailableView("没有背景图", systemImage: "photo", description:
                    Text("把图片放进酒馆的 backgrounds 目录后，这里会出现。"))
            }
        }
        .navigationTitle("背景")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let client = app.client else { return }
        if let reply = try? await client.call("background.list", as: BackgroundListReply.self) {
            backgrounds = reply.backgrounds
        }
    }

    private func select(_ name: String) async {
        guard let client = app.client else { return }
        _ = try? await client.call("background.select", args: ["name": .string(name)], as: SelectedReply.self)
        await load()
        await app.refreshSettings()
    }
}

/// 通用: the miscellaneous switches the tavern keeps in power-user settings.
struct GeneralSettingsView: View {
    @ObservedObject var app: AppModel

    @State private var swipes = true
    @State private var timestamps = true
    @State private var tokenCounts = true
    @State private var messageIds = true
    @State private var autoContinue = false
    @State private var autoScroll = true
    @State private var notice: String?
    @State private var loaded = false

    var body: some View {
        Form {
            Section("聊天显示") {
                Toggle("滑动候选（swipes）", isOn: $swipes)
                Toggle("显示时间戳", isOn: $timestamps)
                Toggle("显示消息词符数", isOn: $tokenCounts)
                Toggle("显示消息编号", isOn: $messageIds)
                Toggle("自动滚动到底部", isOn: $autoScroll)
            }
            Section("生成") {
                Toggle("自动继续生成", isOn: $autoContinue)
            }
            Section {
                Button {
                    Task { await save() }
                } label: {
                    Text("保存")
                }
            } footer: {
                if let notice { Text(notice) }
            }
        }
        .navigationTitle("通用")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard let client = app.client, !loaded else { return }
        struct PowerUser: Decodable {
            let swipes: Bool
            let timestamps: Bool
            let tokenCounts: Bool
            let messageIds: Bool
            let autoContinue: Bool
            let autoScroll: Bool
        }
        if let power = try? await client.call("general.get", as: PowerUser.self) {
            swipes = power.swipes
            timestamps = power.timestamps
            tokenCounts = power.tokenCounts
            messageIds = power.messageIds
            autoContinue = power.autoContinue
            autoScroll = power.autoScroll
        }
        loaded = true
    }

    private func save() async {
        guard let client = app.client else { return }
        struct Saved: Decodable { let saved: Bool }
        do {
            _ = try await client.call(
                "general.save",
                args: [
                    "swipes": .bool(swipes),
                    "timestamps": .bool(timestamps),
                    "tokenCounts": .bool(tokenCounts),
                    "messageIds": .bool(messageIds),
                    "autoContinue": .bool(autoContinue),
                    "autoScroll": .bool(autoScroll),
                ],
                as: Saved.self
            )
            notice = "已保存。"
        } catch {
            notice = "保存失败：\(error.localizedDescription)"
        }
    }
}

/// 本地引擎: status and the log.
struct EngineSettingsView: View {
    @ObservedObject var app: AppModel

    var body: some View {
        List {
            Section("状态") {
                switch app.engine.phase {
                case .idle:
                    Text("尚未启动")
                case .starting:
                    HStack { ProgressView(); Text("正在启动…") }
                case .transportReady(let status):
                    LabeledContent("Node", value: status.runtime)
                    LabeledContent("协议", value: String(status.protocolVersion))
                    LabeledContent("酒馆核心", value: status.sillyTavernCoreReady ? "已运行" : "启动中")
                    LabeledContent("能力", value: "\(status.capabilities.count) 项")
                case .failed(let message):
                    Text(message).foregroundStyle(.red)
                case .exited(let code):
                    Text("引擎线程已退出（\(code)）").foregroundStyle(.red)
                }
            }
            Section {
                NavigationLink {
                    EngineLogView()
                } label: {
                    Label("引擎日志", systemImage: "doc.text.magnifyingglass")
                }
            } footer: {
                Text("世界书扫描、宏展开、提示词组装和模型调用都在 App 内运行的原版酒馆代码里完成。")
            }
        }
        .navigationTitle("本地引擎")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 关于.
struct AboutView: View {
    @ObservedObject var app: AppModel

    var body: some View {
        List {
            Section {
                LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                LabeledContent("酒馆核心", value: "SillyTavern 82b64a4")
                LabeledContent("运行时", value: "NodeMobile 24.20.0")
                LabeledContent("角色", value: "\(app.characters.count)")
                LabeledContent("世界书", value: "\(app.books.count)")
            }
            Section {
                Text("界面与功能都由酒馆自己的代码提供，App 只负责在本地启动它并保护访问入口。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}
