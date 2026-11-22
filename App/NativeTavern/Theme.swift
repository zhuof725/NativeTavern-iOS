import SwiftUI

/// Material system adapted from Apple Glass 2 (SillyTavern-AppleGlassStyles).
///
/// Colours stay as they are in the app; what is taken from the reference is the
/// *structure*: layered translucent panels, a floating input island over the
/// transcript, hairline separators, 0.5pt inner highlights, capsule controls and
/// SF-style type scale.
enum Glass {
    /// Panel behind floating content (cards, list rows).
    static let panel = Color.white.opacity(0.06)
    /// Header/footer bars that sit on the transcript.
    static let bar = Color.white.opacity(0.045)
    /// Floating island (composer, search).
    static let float = Color.white.opacity(0.10)
    /// Selected row.
    static let selected = Color.white.opacity(0.13)
    /// Pressed / hover fill.
    static let pressed = Color.white.opacity(0.08)

    static let hairline = Color.white.opacity(0.09)
    static let hairlineStrong = Color.white.opacity(0.16)
    static let innerHighlight = Color.white.opacity(0.10)

    static let label2 = Color.white.opacity(0.64)
    static let label3 = Color.white.opacity(0.42)

    static let radiusRow: CGFloat = 12
    static let radiusPanel: CGFloat = 20
    static let radiusIsland: CGFloat = 24
}

extension View {
    /// A pane of glass: tinted fill, hairline rim and a 0.5pt inner highlight.
    func glassPanel(radius: CGFloat = Glass.radiusPanel) -> some View {
        self
            .background(Glass.panel, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Glass.hairline, lineWidth: 0.5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Glass.innerHighlight, lineWidth: 0.5)
                    .mask(alignment: .top) { Rectangle().frame(height: 24) }
            }
    }

    /// The floating input island's material.
    func glassIsland() -> some View {
        self
            .background {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Rectangle().fill(Color.black.opacity(0.35))
                }
                .clipShape(RoundedRectangle(cornerRadius: Glass.radiusIsland, style: .continuous))
            }
            .background(Glass.float, in: RoundedRectangle(cornerRadius: Glass.radiusIsland, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Glass.radiusIsland, style: .continuous)
                    .strokeBorder(Glass.hairlineStrong, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }

    /// Standard list row background for grouped, inset content.
    func glassRow(isSelected: Bool = false) -> some View {
        self.background(
            isSelected ? Glass.selected : Color.clear,
            in: RoundedRectangle(cornerRadius: Glass.radiusRow, style: .continuous)
        )
    }
}

import UniformTypeIdentifiers

/// Import pickers: which documents an import flow accepts, and how a chosen
/// file is described back to the user.
enum ImportKind {
    enum Kind { case character, persona, document, photo, any }

    /// Content types per kind. `.item` alone lets the picker show every app, so
    /// each import flow states what it can actually parse.
    static func contentTypes(_ kind: Kind) -> [UTType] {
        switch kind {
        case .character:
            return [.png, .jpeg, .json, .yaml, UTType(filenameExtension: "yml") ?? .data,
                    UTType(filenameExtension: "charx") ?? .data,
                    UTType(filenameExtension: "byaf") ?? .data].compactMap { $0 }
        case .persona:
            return [.png, .jpeg, .json].compactMap { $0 }
        case .document:
            return [.json, .plainText, .yaml, UTType(filenameExtension: "yml") ?? .data].compactMap { $0 }
        case .photo:
            return [.png, .jpeg, .heic, .webP].compactMap { $0 }
        case .any:
            return [.item]
        }
    }

    /// A short, platform right label: the file's extension, or its type name.
    static func typeLabel(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty { return ext.uppercased() }
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           let description = type.localizedDescription {
            return description
        }
        return "文件"
    }

    static func formattedSize(_ data: Data) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }
}

extension View {
    func importPicker(_ isPresented: Binding<Bool>, kind: ImportKind.Kind, onPick: @escaping ([URL]) -> Void) -> some View {
        fileImporter(isPresented: isPresented, allowedContentTypes: ImportKind.contentTypes(kind), allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { onPick(urls) }
        }
    }
}
