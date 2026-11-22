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

/// A UIKit document picker.
///
/// SwiftUI's `fileImporter` is a wrapper with a fixed set of behaviours; using
/// `UIDocumentPickerViewController` directly gives control over the modes and
/// content types, and reports the picked URLs through one delegate that reads
/// each file inside its security scope. The data is copied out before the scope
/// closes, because an import runs several network round-trips afterwards.
final class DocumentPicker: NSObject, UIDocumentPickerDelegate, UIViewControllerRepresentable {
    struct Configuration {
        var types: [UTType] = [.item]
        var allowsMultiple = true
        var copiesOnPick = true
    }

    let configuration: Configuration
    let onPick: ([PickedFile]) -> Void
    let onFailure: (String) -> Void

    init(configuration: Configuration,
         onPick: @escaping ([PickedFile]) -> Void,
         onFailure: @escaping (String) -> Void = { _ in }) {
        self.configuration = configuration
        self.onPick = onPick
        self.onFailure = onFailure
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: configuration.types,
            asCopy: configuration.copiesOnPick
        )
        picker.allowsMultipleSelection = configuration.allowsMultiple
        picker.delegate = self
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    // MARK: UIDocumentPickerDelegate

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        var files: [PickedFile] = []
        var failures: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                // `.copy` already staged the file in the app's inbox; reading it
                // there still benefits from the scope being held.
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                files.append(PickedFile(name: url.lastPathComponent, data: data))
            } catch {
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        if !files.isEmpty { onPick(files) }
        if !failures.isEmpty { onFailure(failures.joined(separator: "\n")) }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // Nothing was selected; the caller's sheet dismisses itself.
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

extension View {
    /// Presents the UIKit picker as a sheet.
    func documentPicker(isPresented: Binding<Bool>,
                        types: [UTType],
                        allowsMultiple: Bool = true,
                        onPick: @escaping ([PickedFile]) -> Void,
                        onFailure: @escaping (String) -> Void = { _ in }) -> some View {
        sheet(isPresented: isPresented) {
            DocumentPicker(
                configuration: .init(types: types, allowsMultiple: allowsMultiple),
                onPick: { files in
                    isPresented.wrappedValue = false
                    onPick(files)
                },
                onFailure: onFailure
            )
            .ignoresSafeArea()
        }
    }
}
