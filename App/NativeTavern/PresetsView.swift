import SwiftUI
import Foundation

struct PresetsView: View {
    @ObservedObject var app: AppModel

    @State private var temperature: Double = 1
    @State private var topP: Double = 1
    @State private var frequencyPenalty: Double = 0
    @State private var presencePenalty: Double = 0
    @State private var maxTokens: Int = 300
    @State private var maxContext: Int = 8192
    @State private var stream = false
    @State private var synced = false
    @State private var saving = false
    @State private var confirmPreset: PresetSummary?
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if app.presets.isEmpty {
                        Text("还没有对话预设。核心默认会提供一份 Default。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(app.presets) { preset in
                        Button {
                            confirmPreset = preset
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(preset.name)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.primary)
                                        if preset.name == app.settings?.presetName {
                                            Text("当前")
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.accentColor.opacity(0.16), in: Capsule())
                                                .foregroundStyle(Color.accentColor)
                                        }
                                    }
                                    Text("温度 \(preset.temperature, specifier: "%.2f") · 上限 \(preset.maxTokens) tokens")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if !preset.model.isEmpty {
                                        Text(preset.model)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("对话预设")
                } footer: {
                    Text("应用预设会覆盖采样参数，并可能切换模型连接；提示词顺序不会被改动。")
                }

                Section("生成参数") {
                    slider("温度", value: $temperature, range: 0...2, step: 0.05)
                    slider("Top P", value: $topP, range: 0...1, step: 0.01)
                    slider("频率惩罚", value: $frequencyPenalty, range: -2...2, step: 0.05)
                    slider("存在惩罚", value: $presencePenalty, range: -2...2, step: 0.05)
                    Stepper("回复上限：\(maxTokens) tokens", value: $maxTokens, in: 64...8192, step: 64)
                    Stepper("上下文：\(maxContext) tokens", value: $maxContext, in: 1024...131072, step: 1024)
                    Toggle("流式传输", isOn: $stream)
                    Button {
                        Task { await save() }
                    } label: {
                        if saving { ProgressView() } else { Text("保存生成参数") }
                    }
                    .disabled(saving)
                }

                Section("提示词") {
                    NavigationLink {
                        PromptListView(app: app)
                    } label: {
                        Label("提示词顺序", systemImage: "list.number")
                    }
                }

                if let notice {
                    Section {
                        Text(notice).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("预设")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await app.refreshPresets()
                await app.refreshSettings()
                syncFromSettings(force: true)
            }
            .onAppear {
                syncFromSettings(force: false)
            }
            .onChange(of: app.settings) { _, _ in
                syncFromSettings(force: false)
            }
            .confirmationDialog(
                "应用预设 \(confirmPreset?.name ?? "")？",
                isPresented: Binding(
                    get: { confirmPreset != nil },
                    set: { if !$0 { confirmPreset = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("应用") {
                    if let preset = confirmPreset {
                        confirmPreset = nil
                        Task {
                            await app.applyPreset(preset)
                            syncFromSettings(force: true)
                            notice = "已应用预设“\(preset.name)”。"
                        }
                    }
                }
                Button("取消", role: .cancel) { confirmPreset = nil }
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func syncFromSettings(force: Bool) {
        guard let settings = app.settings else { return }
        if synced && !force { return }
        temperature = settings.temperature
        topP = settings.topP
        frequencyPenalty = settings.frequencyPenalty
        presencePenalty = settings.presencePenalty
        maxTokens = settings.maxTokens
        maxContext = settings.maxContext
        stream = settings.stream
        synced = true
    }

    private func save() async {
        saving = true
        notice = nil
        let ok = await app.updateSettings([
            "temp_openai": .number(temperature),
            "top_p_openai": .number(topP),
            "freq_pen_openai": .number(frequencyPenalty),
            "pres_pen_openai": .number(presencePenalty),
            "openai_max_tokens": .number(Double(maxTokens)),
            "openai_max_context": .number(Double(maxContext)),
            "stream_openai": .bool(stream),
        ])
        saving = false
        notice = ok ? "生成参数已保存。" : app.errorMessage
    }
}

struct PromptListView: View {
    @ObservedObject var app: AppModel
    @State private var prompts: [PromptEntry] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Section {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }
            Section {
                ForEach(Array(prompts.enumerated()), id: \.element.id) { index, prompt in
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: Binding(
                            get: { prompts[index].enabled },
                            set: { value in
                                prompts[index].enabled = value
                                Task { await toggle(prompt.identifier, value) }
                            }
                        )) {
                            HStack {
                                Text(prompt.name)
                                if prompt.marker {
                                    Text("标记")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        if !prompt.content.isEmpty {
                            Text(prompt.content)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Text(prompt.role.uppercased())
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            } footer: {
                Text("这里控制真正的提示词顺序。关闭一项后，核心组装提示词时不会再发送它。")
            }
        }
        .navigationTitle("提示词顺序")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let client = app.client else { return }
        loading = true
        error = nil
        do {
            let reply = try await client.call("prompt.list", as: PromptListReply.self)
            prompts = reply.prompts
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func toggle(_ identifier: String, _ enabled: Bool) async {
        guard let client = app.client else { return }
        do {
            _ = try await client.call(
                "prompt.toggle",
                args: ["identifier": .string(identifier), "enabled": .bool(enabled)],
                as: ToggleReply.self
            )
        } catch {
            self.error = error.localizedDescription
            await load()
        }
    }
}
