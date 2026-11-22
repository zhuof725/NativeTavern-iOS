import SwiftUI

/// Connection: the API, the provider, the key, and the model — plus the
/// connection test the reference screen offers.
struct ConnectionSettingsView: View {
    @ObservedObject var app: AppModel

    @State private var source = "custom"
    @State private var model = ""
    @State private var customURL = ""
    @State private var reverseProxy = ""
    @State private var apiKey = ""
    @State private var bypassStatusCheck = false
    @State private var showExternalModels = false
    @State private var postProcessing = ""
    @State private var logitBias = ""
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var testing = false
    @State private var saving = false
    @State private var notice: String?
    @State private var synced = false
    @State private var keyVisible = false

    private struct Provider: Identifiable, Hashable {
        let id: String
        let name: String
        let modelKey: String
        let secret: String
    }

    /// The providers the app exposes; each maps to the core's own setting key
    /// and its secret name.
    private static let providers: [Provider] = [
        Provider(id: "custom", name: "自定义 (OpenAI 兼容)", modelKey: "custom_model", secret: "api_key_custom"),
        Provider(id: "openai", name: "OpenAI", modelKey: "openai_model", secret: "api_key_openai"),
        Provider(id: "claude", name: "Claude", modelKey: "claude_model", secret: "api_key_claude"),
        Provider(id: "openrouter", name: "OpenRouter", modelKey: "openrouter_model", secret: "api_key_openrouter"),
        Provider(id: "deepseek", name: "DeepSeek", modelKey: "deepseek_model", secret: "api_key_deepseek"),
        Provider(id: "groq", name: "Groq", modelKey: "groq_model", secret: "api_key_groq"),
        Provider(id: "mistralai", name: "MistralAI", modelKey: "mistralai_model", secret: "api_key_mistralai"),
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
        Form {
            Section("API") {
                LabeledContent("接口类型", value: "聊天补全")
            }

            Section("聊天补全来源") {
                Picker("来源", selection: $source) {
                    ForEach(Self.providers) { item in
                        Text(item.name).tag(item.id)
                    }
                }
                .onChange(of: source) { _, _ in
                    models = []
                    model = app.settings?.currentModel ?? ""
                }
                if source == "custom" {
                    TextField("接口地址（含 /v1）", text: $customURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if source == "openai" {
                    TextField("反向代理（可选）", text: $reverseProxy)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            Section {
                HStack {
                    if keyVisible {
                        TextField("API 密钥", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        SecureField("API 密钥", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Button {
                        keyVisible.toggle()
                    } label: {
                        Image(systemName: keyVisible ? "eye.slash" : "key.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
                if app.settings?.apiKeySet == true {
                    Text("已保存密钥（留空表示不修改）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("密钥")
            }

            Section("模型") {
                if !models.isEmpty {
                    Picker("可用模型", selection: $model) {
                        ForEach(models, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                }
                TextField("模型名", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await loadModels() }
                } label: {
                    HStack {
                        Label("获取模型列表", systemImage: "arrow.down.circle")
                        if loadingModels { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(loadingModels)
            }

            Section {
                Toggle("绕过 API 状态检查", isOn: $bypassStatusCheck)
                Toggle("显示外部模型（由 API 提供）", isOn: $showExternalModels)
                Picker("提示词后处理", selection: $postProcessing) {
                    Text("未选择").tag("")
                    Text("合并").tag("merge")
                    Text("合并（工具）").tag("merge_tools")
                    Text("半严格").tag("semi")
                    Text("半严格（工具）").tag("semi_tools")
                    Text("严格").tag("strict")
                    Text("严格（工具）").tag("strict_tools")
                    Text("单条").tag("single")
                }
                if !(app.settings?.logitBiasPresets.isEmpty ?? true) {
                    Picker("Logit 偏置", selection: $logitBias) {
                        ForEach(app.settings?.logitBiasPresets ?? [], id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                }
            } footer: {
                Text("提示词后处理会把多条系统消息合并成模型支持的形式，多数 OpenAI 兼容服务用“合并”即可。")
            }

            Section {
                Button {
                    Task { await saveAndTest() }
                } label: {
                    HStack {
                        Text("保存并连接")
                        if testing { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(testing || saving)
                Button("发送测试消息") {
                    Task { await testMessage() }
                }
                .disabled(testing || saving)
            } footer: {
                if let notice {
                    Text(notice).foregroundStyle(.secondary)
                } else {
                    Text("密钥写入酒馆自己的密钥库，不进入 App 偏好设置。")
                }
            }
        }
        .navigationTitle("连接")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: sync)
        .onChange(of: app.settings) { _, _ in sync() }
    }

    private func sync() {
        guard let settings = app.settings else { return }
        if synced { return }
        source = settings.source
        model = settings.currentModel
        customURL = settings.customUrl
        reverseProxy = settings.reverseProxy
        bypassStatusCheck = settings.bypassStatusCheck
        showExternalModels = settings.showExternalModels
        postProcessing = settings.postProcessing
        logitBias = settings.logitBiasSelected
        synced = true
    }

    private func loadModels() async {
        guard let client = app.client else { return }
        loadingModels = true
        let reply = try? await client.call("settings.models", as: ModelListReply.self)
        models = reply?.models ?? []
        loadingModels = false
        if models.isEmpty {
            notice = "服务没有返回模型列表；地址或密钥可能不正确。也可以直接填写模型名。"
        }
    }

    private func saveAndTest() async {
        testing = true
        notice = nil
        guard let client = app.client else { testing = false; return }

        var patch: [String: JSONValue] = [
            "chat_completion_source": .string(source),
            "bypass_status_check": .bool(bypassStatusCheck),
            "show_external_models": .bool(showExternalModels),
        ]
        if source == "custom" {
            patch["custom_url"] = .string(customURL.trimmingCharacters(in: .whitespacesAndNewlines))
            patch["custom_model"] = .string(model.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            patch[provider.modelKey] = .string(model.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if source == "openai" {
            patch["reverse_proxy"] = .string(reverseProxy.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !postProcessing.isEmpty {
            patch["custom_prompt_post_processing"] = .string(postProcessing)
        }
        if !logitBias.isEmpty {
            patch["bias_preset_selected"] = .string(logitBias)
        }

        let saved = await app.updateSettings(patch)
        guard saved else {
            notice = app.errorMessage ?? "保存失败。"
            testing = false
            return
        }

        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            let stored = await app.setSecret(key: provider.secret, value: key)
            if stored { apiKey = "" } else { notice = app.errorMessage }
        }

        struct Probe: Decodable { let ok: Bool; let message: String }
        if let probe = try? await client.call("settings.test", as: Probe.self) {
            notice = probe.message
        } else {
            notice = "已保存。连接测试没有返回结果。"
        }
        testing = false
    }

    /// A real generation with a short prompt: the only proof the whole path works.
    private func testMessage() async {
        testing = true
        notice = nil
        do {
            struct Reply: Decodable { let error: String? }
            guard let client = app.client else { testing = false; return }
            let reply = try await client.call(
                "settings.testMessage",
                args: ["text": .string("Hello")],
                as: Reply.self
            )
            notice = reply.error ?? "测试消息已通过：模型可以正常回复。"
        } catch {
            notice = "测试消息失败：\(error.localizedDescription)"
        }
        testing = false
    }
}
