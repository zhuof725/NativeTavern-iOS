import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject var app: AppModel

    @State private var source = "custom"
    @State private var model = ""
    @State private var customURL = ""
    @State private var reverseProxy = ""
    @State private var apiKey = ""
    @State private var userName = ""
    @State private var stream = false
    @State private var synced = false
    @State private var saving = false
    @State private var testing = false
    @State private var notice: String?
    @State private var testResult: String?

    private struct Provider: Identifiable, Hashable {
        let id: String
        let name: String
        let modelKey: String
        let secret: String
    }

    private static let providers: [Provider] = [
        Provider(id: "custom", name: "自定义 OpenAI 兼容", modelKey: "custom_model", secret: "api_key_custom"),
        Provider(id: "openai", name: "OpenAI", modelKey: "openai_model", secret: "api_key_openai"),
        Provider(id: "claude", name: "Claude", modelKey: "claude_model", secret: "api_key_claude"),
        Provider(id: "openrouter", name: "OpenRouter", modelKey: "openrouter_model", secret: "api_key_openrouter"),
        Provider(id: "deepseek", name: "DeepSeek", modelKey: "deepseek_model", secret: "api_key_deepseek"),
        Provider(id: "groq", name: "Groq", modelKey: "groq_model", secret: "api_key_groq"),
        Provider(id: "mistralai", name: "Mistral", modelKey: "mistralai_model", secret: "api_key_mistralai"),
        Provider(id: "makersuite", name: "Google AI Studio", modelKey: "google_model", secret: "api_key_makersuite"),
        Provider(id: "xai", name: "xAI", modelKey: "xai_model", secret: "api_key_xai"),
        Provider(id: "zai", name: "Z.AI", modelKey: "zai_model", secret: "api_key_zai"),
        Provider(id: "perplexity", name: "Perplexity", modelKey: "perplexity_model", secret: "api_key_perplexity"),
        Provider(id: "cohere", name: "Cohere", modelKey: "cohere_model", secret: "api_key_cohere"),
    ]

    private var provider: Provider {
        Self.providers.first { $0.id == source } ?? Self.providers[0]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("服务", selection: $source) {
                        ForEach(Self.providers) { item in
                            Text(item.name).tag(item.id)
                        }
                    }
                    if source == "custom" {
                        TextField("接口地址（含 /v1）", text: $customURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    TextField("模型名", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if source == "openai" {
                        TextField("反向代理（可选）", text: $reverseProxy)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    SecureField("API Key", text: $apiKey)
                    Toggle("流式传输", isOn: $stream)
                    HStack {
                        Button("保存连接") {
                            Task { _ = await saveConnection() }
                        }
                        .disabled(saving || testing)
                        Button("测试连接") {
                            Task { await testConnection() }
                        }
                        .disabled(saving || testing)
                        if saving || testing { ProgressView().controlSize(.small) }
                    }
                    if let testResult {
                        Text(testResult)
                            .font(.caption)
                            .foregroundStyle(testResult.hasPrefix("连接成功") ? Color.secondary : Color.red)
                    }
                } header: {
                    Text("模型连接")
                } footer: {
                    Text("密钥写入酒馆自己的密钥库，不进入 App 偏好设置。自定义地址示例：http://192.168.1.10:8080/v1")
                }

                Section("用户") {
                    TextField("显示名称", text: $userName)
                    Button("保存名称") {
                        Task {
                            let ok = await app.updateSettings(["username": .string(userName)])
                            notice = ok ? "名称已保存。" : app.errorMessage
                        }
                    }
                }

                Section("人设") {
                    if app.personas.isEmpty {
                        Text("还没有人设。酒馆的人设可以在角色卡导入后从设置中创建；当前对话使用上方的显示名称。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(app.personas) { persona in
                        Button {
                            Task { await app.selectPersona(persona) }
                        } label: {
                            HStack(spacing: 10) {
                                EngineImage(client: app.client, path: "User Avatars/\(persona.avatar)")
                                    .frame(width: 34, height: 34)
                                    .clipShape(Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(persona.name).foregroundStyle(.primary)
                                    if !persona.title.isEmpty {
                                        Text(persona.title)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
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

                Section("本地引擎") {
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
                        LabeledContent("角色", value: "\(app.characters.count)")
                        LabeledContent("世界书", value: "\(app.books.count)")
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    case .exited(let code):
                        Text("引擎线程已退出（\(code)）。重新打开 App 才能再次启动。")
                            .foregroundStyle(.red)
                    }
                    NavigationLink {
                        EngineLogView()
                    } label: {
                        Label("引擎日志", systemImage: "doc.text.magnifyingglass")
                    }
                }

                Section("关于") {
                    LabeledContent("酒馆核心", value: "SillyTavern 82b64a4")
                    LabeledContent("运行时", value: "NodeMobile 24.20.0")
                    Text("世界书扫描、宏展开、提示词组装和模型调用都由 App 内运行的原版酒馆代码完成；SwiftUI 只负责人机界面。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let notice {
                    Section {
                        Text(notice).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let error = app.errorMessage {
                    Section {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("设置")
            .refreshable {
                await app.refreshSettings()
                await app.refreshPersonas()
                syncFromSettings(force: true)
            }
            .onAppear { syncFromSettings(force: false) }
            .onChange(of: app.settings) { _, _ in syncFromSettings(force: false) }
        }
    }

    private func syncFromSettings(force: Bool) {
        guard let settings = app.settings else { return }
        if synced && !force { return }
        source = settings.source
        model = settings.currentModel
        customURL = settings.customUrl
        reverseProxy = settings.reverseProxy
        stream = settings.stream
        userName = settings.userName
        synced = true
    }

    @discardableResult
    private func saveConnection(announce: Bool = true) async -> Bool {
        saving = true
        if announce { notice = nil }
        var patch: [String: JSONValue] = [
            "chat_completion_source": .string(source),
        ]
        if source == "custom" {
            patch["custom_url"] = .string(customURL.trimmingCharacters(in: .whitespacesAndNewlines))
            patch["custom_model"] = .string(model.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            patch[provider.modelKey] = .string(model.trimmingCharacters(in: .whitespacesAndNewlines))
            if source == "openai" {
                patch["reverse_proxy"] = .string(reverseProxy.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        patch["stream_openai"] = .bool(stream)
        let ok = await app.updateSettings(patch)
        var keySaved = true
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if ok && !key.isEmpty {
            keySaved = await app.setSecret(key: provider.secret, value: key)
            if keySaved { apiKey = "" }
        }
        saving = false
        let success = ok && keySaved
        if announce {
            notice = success ? "模型连接已保存。" : (app.errorMessage ?? "保存失败。")
        }
        return success
    }

    private func testConnection() async {
        testResult = nil
        let saved = await saveConnection(announce: false)
        guard saved, let client = app.client else {
            testResult = "连接失败：\(app.errorMessage ?? "设置没有保存。")"
            return
        }
        testing = true
        do {
            struct Probe: Decodable { let ok: Bool; let message: String }
            let result = try await client.call("settings.test", as: Probe.self)
            testResult = result.message
        } catch {
            testResult = "连接失败：\(error.localizedDescription)"
        }
        testing = false
    }
}

/// The engine log is the only record after a crash on a device.
struct EngineLogView: View {
    @State private var text: String = "（没有日志）"

    var body: some View {
        ScrollView {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("引擎日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    load()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Image(systemName: "doc.on.doc")
                }
            }
        }
        .task { load() }
    }

    private func load() {
        text = EngineLog.read() ?? "（没有日志）"
    }
}

enum EngineLog {
    static var url: URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: false) else { return nil }
        return support.appendingPathComponent("NativeTavern/engine.log")
    }

    static func read() -> String? {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").suffix(400).joined(separator: "\n")
    }
}
