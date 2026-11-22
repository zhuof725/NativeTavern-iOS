import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A file the user picked, already read into memory.
struct PickedFile: Identifiable {
    let id = UUID()
    let name: String
    let data: Data
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file) }
    var typeLabel: String {
        let ext = (name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "文件" : ext
    }
}

/// Presents `UIDocumentPickerViewController` on top of the app's window.
///
/// SwiftUI cannot host a document picker: it is a modal controller that expects
/// to be presented, and nesting it in a `UIViewControllerRepresentable` inside a
/// sheet is what triggered a SwiftUI assertion (`UIViewControllerRepresentable
/// ._makeView`) on device. Presenting it from the key window's topmost
/// controller is the documented way, and it keeps the picker out of the view
/// hierarchy entirely.
@MainActor
enum DocumentPickerPresenter {
    struct Configuration {
        var types: [UTType] = [.item]
        var allowsMultiple = true
        var copiesOnPick = true
    }

    static func present(configuration: Configuration,
                        onPick: @escaping ([PickedFile]) -> Void,
                        onFailure: @escaping (String) -> Void = { _ in }) {
        guard let presenter = topViewController() else {
            onFailure("找不到可用的窗口，无法打开文件选择器。")
            return
        }
        let coordinator = Coordinator(onPick: onPick, onFailure: onFailure)
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: configuration.types,
            asCopy: configuration.copiesOnPick
        )
        picker.allowsMultipleSelection = configuration.allowsMultiple
        picker.shouldShowFileExtensions = true
        picker.delegate = coordinator
        // The delegate is weak on UIKit's side; the picker is the only strong
        // reference holder, so the coordinator is parked here until it ends.
        presenters[picker] = coordinator
        presenter.present(picker, animated: true)
    }

    /// Live coordinators, keyed by the picker that owns them.
    fileprivate static var presenters: [UIDocumentPickerViewController: Coordinator] = [:]

    /// The controller a modal should be presented from.
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
                ?? scene?.windows.first?.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([PickedFile]) -> Void
        private let onFailure: (String) -> Void

        init(onPick: @escaping ([PickedFile]) -> Void, onFailure: @escaping (String) -> Void) {
            self.onPick = onPick
            self.onFailure = onFailure
        }

        nonisolated func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            // UIKit calls this on the main thread; the protocol itself is not
            // annotated, so isolation is asserted here rather than promised.
            MainActor.assumeIsolated {
                handlePick(controller, urls: urls)
            }
        }

        nonisolated func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            MainActor.assumeIsolated {
                DocumentPickerPresenter.presenters.removeValue(forKey: controller)
            }
        }

        private func handlePick(_ controller: UIDocumentPickerViewController, urls: [URL]) {
            DocumentPickerPresenter.presenters.removeValue(forKey: controller)
            var files: [PickedFile] = []
            var failures: [String] = []
            for url in urls {
                // `asCopy` staged the file in the app's inbox, but the security
                // scope is what guarantees access while it is read.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    files.append(PickedFile(name: url.lastPathComponent, data: data))
                } catch {
                    failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            if !files.isEmpty { onPick(files) }
            if !failures.isEmpty { onFailure(failures.joined(separator: "\n")) }
        }
    }
}

/// Content types each import flow accepts.
enum ImportTypes {
    static var characterCards: [UTType] {
        var types: [UTType] = [.png, .jpeg, .json]
        for ext in ["yaml", "yml", "charx", "byaf"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    static var personaImage: [UTType] { [.png, .jpeg, .heic, .webP] }
    static var presets: [UTType] { [.json] }
}
