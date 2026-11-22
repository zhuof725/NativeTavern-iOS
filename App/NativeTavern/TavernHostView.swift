import SwiftUI

/// The app's single screen: the tavern interface, hosted.
///
/// The interface is the tavern itself, so every feature is reachable without a
/// native re-creation. Swift only supplies what a hosted page cannot: the launch
/// overlay while the embedded core boots, and the engine log when it fails.
struct TavernHostView: View {
    @ObservedObject var app: AppModel

    var body: some View {
        Group {
            if let client = app.client, case .ready = app.phase {
                TavernScreen(client: client)
                    .ignoresSafeArea(.container, edges: .bottom)
            } else {
                LaunchGateView(app: app)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct TavernScreen: UIViewControllerRepresentable {
    let client: LocalEngineClient

    func makeUIViewController(context: Context) -> WebUIController {
        WebUIController(client: client)
    }

    func updateUIViewController(_ controller: WebUIController, context: Context) {}
}

private struct LaunchGateView: View {
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 54))
                .foregroundStyle(Color.accentColor)
            Text("Native Tavern")
                .font(.title.weight(.semibold))
            switch app.phase {
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                NavigationLink("查看引擎日志") { EngineLogView() }
                    .buttonStyle(.bordered)
            default:
                ProgressView().controlSize(.large)
                if case .starting(let message) = app.phase {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }
}
