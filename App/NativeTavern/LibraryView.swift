import SwiftUI

/// The library screens that used to be tabs: world info, presets and prompts.
struct LibraryView: View {
    @ObservedObject var app: AppModel
    let character: CharacterSummary?

    var body: some View {
        List {
            Section {
                NavigationLink {
                    WorldInfoView(app: app)
                } label: {
                    Label("世界书", systemImage: "book.closed")
                }
                NavigationLink {
                    PresetsView(app: app)
                } label: {
                    Label("预设与生成参数", systemImage: "slider.horizontal.3")
                }
                NavigationLink {
                    PromptListView(app: app)
                } label: {
                    Label("提示词顺序", systemImage: "list.number")
                }
            }

            if let character {
                Section {
                    NavigationLink {
                        CharacterDetailView(app: app, character: character)
                    } label: {
                        Label("角色资料与聊天记录", systemImage: "person.text.rectangle")
                    }
                    NavigationLink {
                        CharacterEditorView(app: app, character: character, onSaved: nil)
                    } label: {
                        Label("编辑角色", systemImage: "pencil")
                    }
                }
            }
        }
        .navigationTitle("资料库")
        .navigationBarTitleDisplayMode(.inline)
    }
}
