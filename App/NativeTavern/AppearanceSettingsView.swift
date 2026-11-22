import SwiftUI

/// Reading preferences shared by the chat screen.
///
/// The seven layouts and the accent colours come from the reference: they change
/// how the transcript is drawn, not what it contains, so every style uses the
/// same messages and the same generation path.
enum ReadingStyle: String, CaseIterable, Identifiable {
    case reading, bubble, document, echo, whisper, ripple, hush

    var id: String { rawValue }

    var label: String {
        switch self {
        case .reading: return "阅读"
        case .bubble: return "气泡"
        case .document: return "文档"
        case .echo: return "回声"
        case .whisper: return "低语"
        case .ripple: return "涟漪"
        case .hush: return "轻声"
        }
    }

    /// How the character's message is drawn.
    var showsCard: Bool {
        switch self {
        case .document, .ripple: return true
        default: return false
        }
    }

    var showsAvatar: Bool {
        switch self {
        case .echo, .whisper, .ripple: return true
        default: return false
        }
    }

    var alignment: HorizontalAlignment {
        switch self {
        case .bubble: return .trailing
        default: return .leading
        }
    }
}

enum AccentChoice: String, CaseIterable, Identifiable {
    case blue, purple, pink, orange, green, teal, graphite

    var id: String { rawValue }
    var color: Color {
        switch self {
        case .blue: return Color(red: 0.04, green: 0.52, blue: 1.0)
        case .purple: return Color(red: 0.68, green: 0.36, blue: 0.96)
        case .pink: return Color(red: 1.0, green: 0.28, blue: 0.42)
        case .orange: return Color(red: 1.0, green: 0.62, blue: 0.04)
        case .green: return Color(red: 0.20, green: 0.82, blue: 0.36)
        case .teal: return Color(red: 0.25, green: 0.78, blue: 0.88)
        case .graphite: return Color(red: 0.56, green: 0.56, blue: 0.58)
        }
    }
}

/// The appearance screen: style picker, accent colour, chat background, and the
/// reading knobs.
struct AppearanceSettingsView: View {
    @ObservedObject var app: AppModel

    @State private var style: ReadingStyle = .reading
    @State private var accent: AccentChoice = .blue
    @State private var bodySize: Double = 16
    @State private var lineWidth: Double = 720
    @State private var messageInfo = "hover"
    @State private var reducedMotion = false
    @State private var blur = true
    @State private var backgroundName = ""
    @State private var backgrounds: [BackgroundSummary] = []
    @State private var pickingBackground = false
    @State private var notice: String?
    @State private var loaded = false

    private static let infoOptions: [(String, String)] = [
        ("hover", "悬停时显示"),
        ("always", "总是显示"),
        ("never", "从不显示"),
    ]

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 10)], spacing: 12) {
                    ForEach(ReadingStyle.allCases) { option in
                        Button {
                            style = option
                            Task { await save() }
                        } label: {
                            VStack(spacing: 6) {
                                StylePreview(option: option)
                                    .frame(height: 54)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(style == option ? accent.color : Color.clear, lineWidth: 2)
                                    }
                                Text(option.label)
                                    .font(.caption2)
                                    .foregroundStyle(style == option ? accent.color : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("聊天样式")
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("强调色").font(.subheadline.weight(.medium))
                    Text("按钮、链接、选中态")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        ForEach(AccentChoice.allCases) { choice in
                            Button {
                                accent = choice
                                Task { await save() }
                            } label: {
                                Circle()
                                    .fill(choice.color)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        Circle()
                                            .strokeBorder(Color.primary.opacity(accent == choice ? 0.9 : 0), lineWidth: 2)
                                            .padding(-4)
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 2)
                }

                Button {
                    Task { await loadBackgrounds() }
                    pickingBackground = true
                } label: {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.black)
                            .frame(width: 56, height: 40)
                            .overlay {
                                if !backgroundName.isEmpty, let client = app.client {
                                    EngineImage(client: client, path: "backgrounds/\(backgroundName)")
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                            }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("聊天背景").foregroundStyle(.primary)
                            Text(backgroundName.isEmpty ? "_black" : backgroundName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text("更换…")
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.secondary.opacity(0.18), in: Capsule())
                    }
                }
                .buttonStyle(.plain)
            } header: {
                Text("强调色")
            }

            Section {
                knob("正文字号", detail: "只影响聊天正文，不改酒馆的全局字体缩放",
                     value: $bodySize, range: 13...22, step: 1, suffix: "px")
                knob("行宽", detail: "聊天正文和输入框的最大宽度",
                     value: $lineWidth, range: 480...1000, step: 20, suffix: "px")
                Picker(selection: $messageInfo) {
                    ForEach(Self.infoOptions, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("消息信息")
                        Text("模型、词符数、耗时只在悬停时显示（最后一条常显）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $reducedMotion) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("减少动态效果")
                        Text("跟随系统设置；开启后关闭所有过渡和动画")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $blur) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("毛玻璃")
                        Text("关闭后改用不透明材质，低端设备更流畅")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("阅读")
            } footer: {
                if let notice { Text(notice) }
            }
        }
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: bodySize) { _, _ in Task { await save() } }
        .onChange(of: lineWidth) { _, _ in Task { await save() } }
        .onChange(of: messageInfo) { _, _ in Task { await save() } }
        .onChange(of: reducedMotion) { _, _ in Task { await save() } }
        .onChange(of: blur) { _, _ in Task { await save() } }
        .sheet(isPresented: $pickingBackground, onDismiss: { Task { await load() } }) {
            NavigationStack {
                List {
                    Button("不使用背景（_black）") {
                        pickingBackground = false
                        Task { await selectBackground("") }
                    }
                    ForEach(backgrounds) { background in
                        Button {
                            pickingBackground = false
                            Task { await selectBackground(background.filename) }
                        } label: {
                            HStack {
                                EngineImage(client: app.client, path: "backgrounds/\(background.filename)")
                                    .frame(width: 54, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(background.displayName).foregroundStyle(.primary)
                                Spacer()
                            }
                        }
                    }
                }
                .overlay {
                    if backgrounds.isEmpty {
                        ContentUnavailableView("没有背景图", systemImage: "photo")
                    }
                }
                .navigationTitle("聊天背景")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { pickingBackground = false }
                    }
                }
            }
        }
    }

    private func knob(_ title: String, detail: String, value: Binding<Double>,
                      range: ClosedRange<Double>, step: Double, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Slider(value: value, in: range, step: step)
                Text("\(Int(value.wrappedValue)) \(suffix)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        guard let client = app.client, !loaded else { return }
        struct Look: Decodable {
            let fontScale: Double
            let blur: Bool
            let reducedMotion: Bool
            let background: String
            let style: String
            let accent: String
            let bodySize: Double
            let lineWidth: Double
            let messageInfo: String
        }
        if let look = try? await client.call("appearance.get", as: Look.self) {
            style = ReadingStyle(rawValue: look.style) ?? .reading
            accent = AccentChoice(rawValue: look.accent) ?? .blue
            bodySize = look.bodySize
            lineWidth = look.lineWidth
            messageInfo = look.messageInfo
            reducedMotion = look.reducedMotion
            blur = look.blur
            backgroundName = look.background
        }
        loaded = true
        ReadingPreferences.shared.update(style: style, accent: accent, bodySize: bodySize,
                                         lineWidth: lineWidth, messageInfo: messageInfo,
                                         reducedMotion: reducedMotion, blur: blur,
                                         background: backgroundName)
    }

    private func loadBackgrounds() async {
        guard let client = app.client else { return }
        if let reply = try? await client.call("background.list", as: BackgroundListReply.self) {
            backgrounds = reply.backgrounds
        }
    }

    private func selectBackground(_ name: String) async {
        guard let client = app.client else { return }
        _ = try? await client.call("background.select", args: ["name": .string(name)], as: SelectedReply.self)
        backgroundName = name
        await save()
    }

    private func save() async {
        guard let client = app.client, loaded else { return }
        struct Saved: Decodable { let saved: Bool }
        _ = try? await client.call(
            "appearance.save",
            args: [
                "style": .string(style.rawValue),
                "accent": .string(accent.rawValue),
                "bodySize": .number(bodySize),
                "lineWidth": .number(lineWidth),
                "messageInfo": .string(messageInfo),
                "reducedMotion": .bool(reducedMotion),
                "blur": .bool(blur),
            ],
            as: Saved.self
        )
        ReadingPreferences.shared.update(style: style, accent: accent, bodySize: bodySize,
                                        lineWidth: lineWidth, messageInfo: messageInfo,
                                        reducedMotion: reducedMotion, blur: blur,
                                        background: backgroundName)
        notice = "已保存。"
    }
}

/// Miniature of each layout: two blocks is enough to tell them apart.
private struct StylePreview: View {
    let option: ReadingStyle

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 4) {
                switch option {
                case .reading:
                    bar(0.9, height: 4, shade: 0.45)
                    bar(0.7, height: 4, shade: 0.30)
                    bar(0.85, height: 4, shade: 0.22)
                case .bubble:
                    bar(0.55, height: 10, shade: 0.35, radius: 5)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    bar(0.75, height: 10, shade: 0.24, radius: 5)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                case .document:
                    bar(0.95, height: 4, shade: 0.28)
                    bar(0.75, height: 4, shade: 0.28)
                    bar(0.88, height: 4, shade: 0.28)
                case .echo:
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.3)).frame(width: 10)
                        VStack(alignment: .leading, spacing: 3) {
                            bar(0.7, height: 4, shade: 0.3)
                            bar(0.55, height: 4, shade: 0.22)
                        }
                    }
                case .whisper:
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.25)).frame(width: 6)
                        bar(0.7, height: 3, shade: 0.22)
                    }
                case .ripple:
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.35)).frame(width: 14)
                        VStack(alignment: .leading, spacing: 3) {
                            bar(0.65, height: 4, shade: 0.28)
                            bar(0.5, height: 4, shade: 0.2)
                        }
                    }
                case .hush:
                    HStack(spacing: 3) {
                        Rectangle().fill(Color.accentColor.opacity(0.7)).frame(width: 2)
                        bar(0.75, height: 3, shade: 0.2)
                    }
                }
            }
            .frame(width: geometry.size.width - 12, height: geometry.size.height - 10, alignment: .topLeading)
            .padding(6)
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func bar(_ fraction: Double, height: CGFloat, shade: Double, radius: CGFloat = 2) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.secondary.opacity(shade))
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, max(0, (1 - fraction) * 100))
    }
}
