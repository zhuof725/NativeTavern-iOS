import SwiftUI

/// Text helpers shared by the list and the reading column.
enum ContentFormatter {
    /// Removes Markdown emphasis that is noise in a one-line preview.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "_", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Shows the exact messages the core would send, plus the world info it injected.
struct PromptPreviewView: View {
    let client: LocalEngineClient
    let character: CharacterSummary?

    @State private var prompt: BuiltPrompt?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Section {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }
            if let prompt {
                let injected = prompt.worldInfo.before + prompt.worldInfo.after
                Section("世界书注入") {
                    if injected.isEmpty {
                        Text("本次没有条目被激活。").foregroundStyle(.secondary)
                    } else {
                        Text(injected).font(.footnote.monospaced())
                    }
                }
                Section("最终提示词（\(prompt.prompt.count) 条）") {
                    ForEach(Array(prompt.prompt.enumerated()), id: \.offset) { _, message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.role.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(message.content).font(.footnote.monospaced())
                        }
                        .padding(.vertical, 2)
                    }
                }
            } else if loading {
                HStack { ProgressView(); Text("正在组装…") }
            } else {
                Text("点右上角刷新，核心会重新组装一次。")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("最终提示词")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    if loading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(loading)
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        error = nil
        var args: [String: JSONValue] = ["maxContext": .number(8192)]
        if let character {
            args["character"] = .object([
                "name": .string(character.name),
                "description": .string(character.description),
                "personality": .string(character.personality),
                "scenario": .string(character.scenario),
            ])
        }
        do {
            prompt = try await client.call("prompt.build", args: args, as: BuiltPrompt.self)
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
