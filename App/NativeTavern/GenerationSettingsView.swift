import SwiftUI

/// 生成参数: the preset picker, context/reply lengths, stream switch, and every
/// sampler the reference screens expose.
struct GenerationSettingsView: View {
    @ObservedObject var app: AppModel

    @State private var source = 0.0
    @State private var maxContext = 8192
    @State private var maxTokens = 300
    @State private var unlocked = false
    @State private var temperature = 1.0
    @State private var frequencyPenalty = 0.0
    @State private var presencePenalty = 0.0
    @State private var topP = 1.0
    @State private var topK = 0.0
    @State private var stream = true
    @State private var n = 1
    @State private var seed = -1.0
    @State private var namesBehavior = 0
    @State private var continuePostfix = " "
    @State private var mediaInlining = true
    @State private var imageQuality = "auto"
    @State private var reasoningEffort = "auto"
    @State private var selectedPreset = ""
    @State private var saving = false
    @State private var notice: String?
    @State private var synced = false
    @State private var presets: [PresetSummary] = []

    private static let nameBehaviors = ["（默认）", "包含名称", "在内容中"]
    private static let nameValues = [0, 1, 2]
    private static let postfixes: [(String, String)] = [
        ("无", ""), ("空格", " "), ("换行", "\n"), ("双换行", "\n\n"),
    ]
    private static let qualities = ["auto", "low", "medium", "high"]
    private static let efforts = ["auto", "low", "medium", "high", "min", "max"]

    var body: some View {
        Form {
            Section {
                Picker("对话补全预设", selection: $selectedPreset) {
                    ForEach(presets) { preset in
                        Text(preset.name).tag(preset.name)
                    }
                }
                .onChange(of: selectedPreset) { _, value in
                    guard !value.isEmpty, value != app.settings?.presetName else { return }
                    Task { await applyPreset(value) }
                }
                HStack(spacing: 18) {
                    Button {
                        Task { await app.refreshPresets() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    NavigationLink {
                        PresetManagerView(app: app)
                    } label: {
                        Image(systemName: "slider.horizontal.below.square.filled.and.square")
                    }
                    Spacer()
                    NavigationLink {
                        PresetManagerView(app: app)
                    } label: {
                        Text("更多操作")
                    }
                }
                .buttonStyle(.borderless)
            } footer: {
                Text("单击滑块以手动输入值。")
            }

            Section {
                Toggle("解锁上下文长度", isOn: $unlocked)
                VStack(alignment: .leading, spacing: 4) {
                    Text("上下文长度（以词符数计）")
                    HStack {
                        TextField("上下文", value: $maxContext, format: .number)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                        if !unlocked {
                            Text("上限 \(maxContext)") 
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Stepper(value: $maxTokens, in: 16...32768, step: 64) {
                    LabeledContent("最大回复长度", value: "\(maxTokens)")
                }
            } footer: {
                Text("AI 可见的最大上下文长度。解锁后可以填入模型真正支持的大小。")
            }

            Section {
                Toggle("流式传输", isOn: $stream)
                Stepper(value: $n, in: 1...8) {
                    LabeledContent("每次生成多个备选回复", value: "\(n)")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("温度")
                    Slider(value: $temperature, in: 0...2, step: 0.01)
                    Text(String(format: "%.2f", temperature))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                slider("频率惩罚", value: $frequencyPenalty, range: -2...2)
                slider("存在惩罚", value: $presencePenalty, range: -2...2)
                slider("Top P", value: $topP, range: 0...1, digits: 2)
                Stepper(value: $topK, in: 0...200, step: 5) {
                    LabeledContent("Top K", value: topK == 0 ? "关" : "\(Int(topK))")
                }
            } footer: {
                Text("流式传输会随着回复生成逐词显示；关闭后一次性显示。")
            }

            Section {
                Picker("角色名称行为", selection: $namesBehavior) {
                    ForEach(Array(Self.nameBehaviors.enumerated()), id: \.offset) { index, label in
                        Text(label).tag(Self.nameValues[index])
                    }
                }
                Picker("继续后缀", selection: $continuePostfix) {
                    ForEach(Self.postfixes, id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
                Toggle("发送内联媒体", isOn: $mediaInlining)
                Picker("图片画质", selection: $imageQuality) {
                    ForEach(Self.qualities, id: \.self) { Text($0).tag($0) }
                }
                Picker("推理强度", selection: $reasoningEffort) {
                    ForEach(Self.efforts, id: \.self) { Text(reasoningLabel($0)).tag($0) }
                }
            } footer: {
                Text("推理强度按“低、中、高”依次递增；自动不会发送推理参数。内联媒体只有在模型支持时才会生效。")
            }

            Section {
                TextField("种子（-1 为随机）", value: $seed, format: .number)
                    .keyboardType(.numbersAndPunctuation)
            } footer: {
                Text("设置此值可得到确定性结果。")
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Text("保存生成参数")
                        if saving { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(saving)
                if let notice {
                    Text(notice).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("生成参数")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            sync()
            Task { await app.refreshPresets(); await loadPresets() }
        }
        .onChange(of: app.settings) { _, _ in sync() }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, digits: Int = 2) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.\(digits)f", value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func reasoningLabel(_ value: String) -> String {
        switch value {
        case "auto": return "自动"
        case "low": return "低"
        case "medium": return "中"
        case "high": return "高"
        case "min": return "极低"
        case "max": return "最高"
        default: return value
        }
    }

    private func loadPresets() async {
        guard let client = app.client else { return }
        if let reply = try? await client.call("preset.list", as: PresetListReply.self) {
            presets = reply.presets
            if selectedPreset.isEmpty { selectedPreset = reply.current }
        }
    }

    private func applyPreset(_ name: String) async {
        guard let client = app.client else { return }
        struct Applied: Decodable { let applied: String }
        _ = try? await client.call("preset.apply", args: ["name": .string(name)], as: Applied.self)
        await app.refreshSettings()
        synced = false
        sync()
    }

    private func sync() {
        guard let settings = app.settings, !synced else { return }
        maxContext = settings.maxContext
        maxTokens = settings.maxTokens
        unlocked = settings.maxContextUnlocked
        temperature = settings.temperature
        frequencyPenalty = settings.frequencyPenalty
        presencePenalty = settings.presencePenalty
        topP = settings.topP
        topK = settings.topK
        stream = settings.stream
        n = settings.n
        seed = settings.seed
        namesBehavior = settings.namesBehavior
        continuePostfix = settings.continuePostfix
        mediaInlining = settings.mediaInlining
        imageQuality = settings.inlineImageQuality
        reasoningEffort = settings.reasoningEffort
        selectedPreset = settings.presetName
        synced = true
    }

    private func save() async {
        saving = true
        notice = nil
        let patch: [String: JSONValue] = [
            "max_context_unlocked": .bool(unlocked),
            "openai_max_context": .number(Double(maxContext)),
            "openai_max_tokens": .number(Double(maxTokens)),
            "temp_openai": .number(temperature),
            "freq_pen_openai": .number(frequencyPenalty),
            "pres_pen_openai": .number(presencePenalty),
            "top_p_openai": .number(topP),
            "top_k_openai": .number(topK),
            "stream_openai": .bool(stream),
            "n": .number(Double(n)),
            "seed": .number(seed),
            "names_behavior": .number(Double(namesBehavior)),
            "continue_postfix": .string(continuePostfix),
            "media_inlining": .bool(mediaInlining),
            "inline_image_quality": .string(imageQuality),
            "reasoning_effort": .string(reasoningEffort),
        ]
        let ok = await app.updateSettings(patch)
        saving = false
        notice = ok ? "生成参数已保存。" : (app.errorMessage ?? "保存失败。")
    }
}
