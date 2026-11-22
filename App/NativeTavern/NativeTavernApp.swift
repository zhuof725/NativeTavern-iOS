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

/// One screen, plus what a hosted page cannot provide: launch progress and the
/// engine log after a failure.
struct RootView: View {
    @ObservedObject var app: AppModel

    var body: some View {
        NavigationStack {
            TavernHostView(app: app)
        }
        .task {
            if !app.isReady {
                await app.boot()
            }
        }
        .alert("出错了", isPresented: $app.showErrorAlert) {
            Button("好", role: .cancel) { app.errorMessage = nil }
        } message: {
            Text(app.errorMessage ?? "")
        }
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
