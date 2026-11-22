import Foundation
import Combine

/// App-wide state: the engine, the character library, world books and the
/// settings snapshot the native screens edit.
///
/// The engine owns all SillyTavern behaviour. This object only decides what to
/// show and which upstream operation to call.
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case starting(String)
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .starting("正在启动本地引擎…")
    @Published private(set) var characters: [CharacterSummary] = []
    @Published private(set) var books: [WorldBookSummary] = []
    @Published private(set) var presets: [PresetSummary] = []
    @Published private(set) var personas: [PersonaSummary] = []
    @Published private(set) var settings: SettingsSnapshot?
    @Published var errorMessage: String?

    let engine = EmbeddedEngine.shared

    var client: LocalEngineClient? { engine.client }
    var isReady: Bool { phase == .ready }

    // MARK: Launch

    func boot() async {
        engine.start()
        let deadline = Date().addingTimeInterval(240)
        var lastStatus = ""
        while Date() < deadline {
            if let client = engine.client {
                if let status = try? await client.status(), status.sillyTavernCoreReady {
                    phase = .starting("正在读取角色与世界书…")
                    await loadAll()
                    if case .failed = phase { return }
                    phase = .ready
                    return
                }
                lastStatus = "正在加载原版酒馆核心…"
            } else {
                lastStatus = "正在启动本地运行时…"
            }
            phase = .starting(lastStatus)
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        phase = .failed("本地引擎启动超时。可在“设置 → 引擎日志”查看原因。")
    }

    private func loadAll() async {
        await refreshCharacters()
        await refreshBooks()
        await refreshSettings()
        await refreshPresets()
        await refreshPersonas()
    }

    // MARK: Characters

    func refreshCharacters() async {
        guard let client else { return }
        do {
            let reply = try await client.call("character.list", as: CharacterListReply.self)
            characters = reply.characters
        } catch {
            errorMessage = "角色列表读取失败：\(error.localizedDescription)"
        }
    }

    func character(avatar: String) -> CharacterSummary? {
        characters.first { $0.avatar == avatar }
    }

    @discardableResult
    func createCharacter(_ draft: CharacterDraft) async -> CharacterSummary? {
        guard let client else { return nil }
        do {
            let reply = try await client.call(
                "character.create",
                args: ["card": .object(draft.json)],
                as: CharacterReply.self
            )
            await refreshCharacters()
            return reply.character
        } catch {
            errorMessage = "创建角色失败：\(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func updateCharacter(avatar: String, draft: CharacterDraft) async -> CharacterSummary? {
        guard let client else { return nil }
        do {
            let reply = try await client.call(
                "character.edit",
                args: ["avatar": .string(avatar), "card": .object(draft.json)],
                as: CharacterReply.self
            )
            await refreshCharacters()
            return reply.character
        } catch {
            errorMessage = "保存角色失败：\(error.localizedDescription)"
            return nil
        }
    }

    func deleteCharacter(_ character: CharacterSummary) async {
        guard let client else { return }
        do {
            struct Deleted: Decodable { let deleted: String }
            _ = try await client.call(
                "character.delete",
                args: ["avatar": .string(character.avatar), "deleteChats": .bool(true)],
                as: Deleted.self
            )
            await refreshCharacters()
        } catch {
            errorMessage = "删除角色失败：\(error.localizedDescription)"
        }
    }

    func importCharacter(fileName: String, data: Data) async -> CharacterSummary? {
        guard let client else { return nil }
        do {
            struct Imported: Decodable { let fileName: String }
            let imported = try await client.call(
                "character.import",
                args: ["fileName": .string(fileName), "data": .string(data.base64EncodedString())],
                as: Imported.self
            )
            await refreshCharacters()
            return characters.first { $0.avatar == imported.fileName }
        } catch {
            errorMessage = "导入角色失败：\(error.localizedDescription)"
            return nil
        }
    }

    func setAvatar(avatar: String, data: Data) async {
        guard let client else { return }
        do {
            struct Updated: Decodable { let avatar: String }
            _ = try await client.call(
                "character.setAvatar",
                args: ["avatar": .string(avatar), "data": .string(data.base64EncodedString()), "fileName": .string("avatar.png")],
                as: Updated.self
            )
            await refreshCharacters()
        } catch {
            errorMessage = "更新头像失败：\(error.localizedDescription)"
        }
    }

    // MARK: Chats

    func chats(for avatar: String) async -> [ChatSummary] {
        guard let client else { return [] }
        do {
            let reply = try await client.call(
                "chat.list",
                args: ["avatar": .string(avatar)],
                as: ChatListReply.self
            )
            return reply.chats
        } catch {
            errorMessage = "聊天列表读取失败：\(error.localizedDescription)"
            return []
        }
    }

    func deleteChat(avatar: String, fileName: String) async {
        guard let client else { return }
        do {
            struct Deleted: Decodable { let deleted: String }
            _ = try await client.call(
                "chat.delete",
                args: ["avatar": .string(avatar), "fileName": .string(fileName)],
                as: Deleted.self
            )
        } catch {
            errorMessage = "删除聊天失败：\(error.localizedDescription)"
        }
    }

    func renameChat(avatar: String, fileName: String, newName: String) async {
        guard let client else { return }
        do {
            struct Renamed: Decodable { let fileName: String }
            _ = try await client.call(
                "chat.rename",
                args: [
                    "avatar": .string(avatar),
                    "fileName": .string(fileName),
                    "newName": .string(newName),
                ],
                as: Renamed.self
            )
        } catch {
            errorMessage = "重命名失败：\(error.localizedDescription)"
        }
    }

    // MARK: World info

    func refreshBooks() async {
        guard let client else { return }
        do {
            let reply = try await client.call("worldinfo.summary", args: [:], as: WorldBookListReply.self)
            books = reply.books
        } catch {
            errorMessage = "世界书列表读取失败：\(error.localizedDescription)"
        }
    }

    func toggleBook(_ book: WorldBookSummary) async {
        guard let client else { return }
        do {
            struct Active: Decodable { let active: [String] }
            if book.active {
                // The engine deactivates by name; removing every other name
                // would be wrong, so only the tapped book is turned off.
                let current = books.filter { $0.active && $0.name != book.name }.map(\.name)
                _ = try await client.call("worldinfo.deactivateAll", as: Active.self)
                if !current.isEmpty {
                    _ = try await client.call(
                        "worldinfo.activate",
                        args: ["names": .array(current.map { .string($0) })],
                        as: Active.self
                    )
                }
            } else {
                _ = try await client.call(
                    "worldinfo.activate",
                    args: ["names": .array([.string(book.name)])],
                    as: Active.self
                )
            }
            await refreshBooks()
        } catch {
            errorMessage = "切换世界书失败：\(error.localizedDescription)"
        }
    }

    func deleteBook(_ book: WorldBookSummary) async {
        guard let client else { return }
        do {
            struct Deleted: Decodable { let deleted: String }
            _ = try await client.call(
                "worldinfo.deleteBook",
                args: ["name": .string(book.name)],
                as: Deleted.self
            )
            await refreshBooks()
        } catch {
            errorMessage = "删除世界书失败：\(error.localizedDescription)"
        }
    }

    // MARK: Presets, prompts, settings

    func refreshPresets() async {
        guard let client else { return }
        do {
            let reply = try await client.call("preset.list", as: PresetListReply.self)
            presets = reply.presets
        } catch {
            errorMessage = "预设读取失败：\(error.localizedDescription)"
        }
    }

    func applyPreset(_ preset: PresetSummary) async {
        guard let client else { return }
        do {
            struct Applied: Decodable { let applied: String }
            _ = try await client.call(
                "preset.apply",
                args: ["name": .string(preset.name)],
                as: Applied.self
            )
            await refreshSettings()
            await refreshPresets()
        } catch {
            errorMessage = "应用预设失败：\(error.localizedDescription)"
        }
    }

    func refreshSettings() async {
        guard let client else { return }
        do {
            settings = try await client.call("settings.snapshot", as: SettingsSnapshot.self)
        } catch {
            errorMessage = "设置读取失败：\(error.localizedDescription)"
        }
    }

    func updateSettings(_ patch: [String: JSONValue]) async -> Bool {
        guard let client else { return false }
        do {
            struct Updated: Decodable { let updated: [String] }
            _ = try await client.call(
                "settings.update",
                args: ["patch": .object(patch)],
                as: Updated.self
            )
            await refreshSettings()
            return true
        } catch {
            errorMessage = "保存设置失败：\(error.localizedDescription)"
            return false
        }
    }

    func setSecret(key: String, value: String) async -> Bool {
        guard let client else { return false }
        do {
            struct Keyed: Decodable { let key: String }
            _ = try await client.call(
                "settings.setSecret",
                args: ["key": .string(key), "value": .string(value)],
                as: Keyed.self
            )
            return true
        } catch {
            errorMessage = "保存密钥失败：\(error.localizedDescription)"
            return false
        }
    }

    func refreshPersonas() async {
        guard let client else { return }
        do {
            let reply = try await client.call("persona.list", as: PersonaListReply.self)
            personas = reply.personas
        } catch {
            errorMessage = "人设读取失败：\(error.localizedDescription)"
        }
    }

    func selectPersona(_ persona: PersonaSummary) async {
        guard let client else { return }
        do {
            struct Selected: Decodable { let name: String }
            _ = try await client.call(
                "persona.select",
                args: ["avatar": .string(persona.avatar)],
                as: Selected.self
            )
            await refreshPersonas()
            await refreshSettings()
        } catch {
            errorMessage = "切换人设失败：\(error.localizedDescription)"
        }
    }
}
