import SwiftUI

@main
struct NativeTavernApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(app: app)
        }
    }
}

struct RootView: View {
    @ObservedObject var app: AppModel

    var body: some View {
        Group {
            switch app.phase {
            case .ready:
                MainTabs(app: app)
            case .starting(let message):
                LaunchView(app: app, message: message)
            case .failed(let message):
                LaunchFailureView(message: message)
            }
        }
        .task {
            if !app.isReady {
                await app.boot()
            }
        }
        .alert("出错了", isPresented: Binding(
            get: { app.errorMessage != nil },
            set: { if !$0 { app.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { app.errorMessage = nil }
        } message: {
            Text(app.errorMessage ?? "")
        }
    }
}

private struct MainTabs: View {
    @ObservedObject var app: AppModel

    var body: some View {
        TabView {
            CharactersView(app: app)
                .tabItem { Label("角色", systemImage: "person.2.fill") }

            GroupsView(app: app)
                .tabItem { Label("群聊", systemImage: "person.3.fill") }

            WorldInfoView(app: app)
                .tabItem { Label("世界书", systemImage: "book.closed.fill") }

            NavigationStack { SettingsHomeView(app: app) }
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
    }
}

private struct LaunchView: View {
    @ObservedObject var app: AppModel
    let message: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 54))
                .foregroundStyle(Color.accentColor)
            Text("Native Tavern")
                .font(.title.weight(.semibold))
            ProgressView()
                .controlSize(.large)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("原版酒馆核心正在 App 内加载。首次启动会复制数据模板，通常需要半分钟。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding()
    }
}

private struct LaunchFailureView: View {
    let message: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("本地引擎没有启动", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                NavigationLink("查看引擎日志") {
                    EngineLogView()
                }
                .buttonStyle(.bordered)
            }
            .navigationTitle("Native Tavern")
        }
    }
}
