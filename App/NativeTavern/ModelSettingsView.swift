import SwiftUI

/// Model connection settings.
///
/// These write through the original core's own settings path, so the core and
/// the vendored server agree on the provider before the first generation.
struct ModelSettingsView: View {
    @ObservedObject var engine: EmbeddedEngine

    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var status: String?
    @State private var saving = false

    var body: some View {
        Form {
            Section("模型服务") {
                TextField("接口地址（OpenAI 兼容）", text: $baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("模型名", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Key", text: $apiKey)
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView() } else { Text("保存并应用") }
                }
                .disabled(saving || engine.client == nil)
            } footer: {
                Text("地址留空表示使用官方 OpenAI。密钥通过酒馆自己的密钥库保存，不会写入本 App 的偏好设置。")
            }

            if let status {
                Section("结果") {
                    Text(status).font(.footnote)
                }
            }
        }
        .navigationTitle("模型设置")
        .task { await load() }
    }

    private func load() async {
        guard let client = engine.client else { return }
        struct SettingsReply: Decodable {
            let settings: Settings?
            struct Settings: Decodable {
                let chat_completion_source: String?
                let openai_model: String?
                let custom_model: String?
                let custom_url: String?
            }
        }
        if let reply = try? await client.call("settings.get", args: [:], as: SettingsReply.self),
           let settings = reply.settings {
            let isCustom = settings.chat_completion_source == "custom"
            baseURL = isCustom ? (settings.custom_url ?? "") : ""
            model = (isCustom ? settings.custom_model : settings.openai_model) ?? ""
        }
    }

    private func save() async {
        guard let client = engine.client else { return }
        saving = true
        status = nil
        do {
            struct Updated: Decodable { let updated: [String] }
            let isCustom = !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            var patch: [String: JSONValue] = [
                "chat_completion_source": .string(isCustom ? "custom" : "openai"),
                "openai_max_tokens": .number(600),
                "openai_max_context": .number(8192),
                "stream_openai": .bool(false),
            ]
            if isCustom {
                patch["custom_url"] = .string(baseURL)
                patch["custom_model"] = .string(model)
            } else {
                patch["openai_model"] = .string(model.isEmpty ? "gpt-4o-mini" : model)
            }
            _ = try await client.call("settings.update", args: ["patch": .object(patch)], as: Updated.self)

            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                struct Keyed: Decodable { let key: String }
                _ = try await client.call(
                    "settings.setSecret",
                    args: ["key": .string("api_key_custom"), "value": .string(key)],
                    as: Keyed.self
                )
                apiKey = ""
            }
            status = "已保存。回聊天页即可生成。"
        } catch {
            status = "保存失败：\(error.localizedDescription)"
        }
        saving = false
    }
}
