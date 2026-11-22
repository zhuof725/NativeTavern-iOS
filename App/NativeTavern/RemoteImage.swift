import SwiftUI
import UIKit

/// Small in-memory cache: avatars are fetched from the core's own static route
/// on every screen, and a conversation re-renders often.
final class EngineImageCache {
    static let shared = EngineImageCache()
    private var images: [String: UIImage] = [:]
    private var order: [String] = []
    private let limit = 160

    func image(for key: String) -> UIImage? { images[key] }

    func store(_ image: UIImage, for key: String) {
        if images[key] == nil { order.append(key) }
        images[key] = image
        while order.count > limit {
            let oldest = order.removeFirst()
            images.removeValue(forKey: oldest)
        }
    }
}

/// An image served by the in-app core (`characters/…`, `User Avatars/…`).
/// Requests carry the per-launch token, so AsyncImage cannot be used.
struct EngineImage: View {
    let client: LocalEngineClient?
    let path: String
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.16))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                Image(systemName: "person.crop.square")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: path) { await load() }
    }

    private func load() async {
        if let cached = EngineImageCache.shared.image(for: path) {
            image = cached
            return
        }
        guard let client else { return }
        do {
            let data = try await client.fetch(path: path)
            if let ui = UIImage(data: data) {
                EngineImageCache.shared.store(ui, for: path)
                image = ui
            } else {
                failed = true
            }
        } catch {
            failed = true
        }
    }
}
