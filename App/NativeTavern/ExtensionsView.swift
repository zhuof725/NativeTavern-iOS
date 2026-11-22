import SwiftUI

/// Installed extensions: what they are, whether they load, and the four
/// operations the tavern's extension manager offers — install from a git URL,
/// update, switch branch, delete.
struct ExtensionsView: View {
    @ObservedObject var app: AppModel

    @State private var extensions: [ExtensionSummary] = []
    @State private var loading = false
    @State private var installing = false
    @State private var installURL = ""
    @State private var installBranch = ""
    @State private var busy = false
    @State private var pendingDelete: ExtensionSummary?
    @State private var pendingUpdate: ExtensionSummary?
    @State private var notice: String?
    @State private var showReloadHint = false

    struct ExtensionSummary: Decodable, Identifiable, Hashable {
        let name: String
        let shortName: String
        let type: String
        let displayName: String
        let version: String
        let author: String
        let description: String
        let enabled: Bool
        let hasManifest: Bool

        var id: String { name }
        var typeLabel: String {
            switch type {
            case "system": return "内置"
            case "local": return "已安装"
            case "global": return "全局"
            default: return type
            }
        }
    }

    struct ListReply: Decodable { let extensions: [ExtensionSummary] }

    var body: some View {
        List {
            if showReloadHint {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("扩展的启用状态会在下次启动时生效")
                                .font(.footnote.weight(.medium))
                            Text("酒馆页面在启动时加载扩展；装好后重启 App 即可。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button {
                            showReloadHint = false
                        } label: {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if extensions.isEmpty && !loading {
                Section {
                    Text("还没有安装扩展。可以从 GitHub 仓库地址安装，例如作者/仓库名。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(extensions) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(item.displayName)
                                .font(.subheadline.weight(.semibold))
                            Text(item.typeLabel)
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.16), in: Capsule())
                                .foregroundStyle(.secondary)
                            Spacer()
                            if !item.version.isEmpty {
                                Text("v\(item.version)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !item.description.isEmpty {
                            Text(item.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        if !item.author.isEmpty {
                            Text(item.author)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        HStack(spacing: 12) {
                            Toggle("启用", isOn: Binding(
                                get: { item.enabled },
                                set: { value in Task { await toggle(item, enabled: value) } }
                            ))
                            .labelsHidden()
                            .disabled(busy)
                            Text(item.enabled ? "已启用" : "已停用")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if item.type != "system" {
                                Button("更新") { pendingUpdate = item }
                                    .font(.caption)
                                    .buttonStyle(.borderless)
                                    .disabled(busy)
                                Button("删除", role: .destructive) { pendingDelete = item }
                                    .font(.caption)
                                    .buttonStyle(.borderless)
                                    .disabled(busy)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                HStack {
                    Text("已安装（\(extensions.count)）")
                    if busy || loading {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .navigationTitle("扩展")
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    installURL = ""
                    installBranch = ""
                    installing = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("安装扩展")
            }
        }
        .alert("从 GitHub 安装", isPresented: $installing) {
            TextField("仓库地址", text: $installURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("分支（可选）", text: $installBranch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) {}
            Button("安装") {
                Task { await install() }
            }
        } message: {
            Text("地址形如 https://github.com/作者/仓库。安装后需要重启 App 才会加载。")
        }
        .alert("更新这个扩展？", isPresented: Binding(
            get: { pendingUpdate != nil },
            set: { if !$0 { pendingUpdate = nil } }
        )) {
            Button("取消", role: .cancel) { pendingUpdate = nil }
            Button("更新") {
                if let item = pendingUpdate {
                    pendingUpdate = nil
                    Task { await update(item) }
                }
            }
        } message: {
            Text(pendingUpdate?.displayName ?? "")
        }
        .alert("删除这个扩展？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let item = pendingDelete {
                    pendingDelete = nil
                    Task { await remove(item) }
                }
            }
        } message: {
            Text(pendingDelete?.displayName ?? "")
        }
        .alert("完成", isPresented: Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )) {
            Button("好", role: .cancel) { notice = nil }
        } message: {
            Text(notice ?? "")
        }
        .task { await load() }
    }

    private func load() async {
        guard let client = app.client else { return }
        loading = true
        do {
            let reply = try await client.call("extension.list", as: ListReply.self)
            extensions = reply.extensions.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
        } catch {
            app.errorMessage = "扩展列表读取失败：\(error.localizedDescription)"
        }
        loading = false
    }

    private func toggle(_ item: ExtensionSummary, enabled: Bool) async {
        guard let client = app.client else { return }
        busy = true
        do {
            struct Toggled: Decodable { let name: String; let enabled: Bool }
            _ = try await client.call(
                "extension.toggle",
                args: ["name": .string(item.name), "enabled": .bool(enabled)],
                as: Toggled.self
            )
            await load()
            showReloadHint = true
        } catch {
            notice = "切换失败：\(error.localizedDescription)"
        }
        busy = false
    }

    private func install() async {
        guard let client = app.client else { return }
        let url = installURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        busy = true
        do {
            struct Installed: Decodable { let installed: InstallInfo
                struct InstallInfo: Decodable { let display_name: String? }
            }
            let reply = try await client.call(
                "extension.install",
                args: ["url": .string(url), "branch": .string(installBranch.trimmingCharacters(in: .whitespaces))],
                as: Installed.self
            )
            await load()
            showReloadHint = true
            notice = "已安装 \(reply.installed.display_name ?? url)。重启 App 后生效。"
        } catch {
            notice = "安装失败：\(error.localizedDescription)"
        }
        busy = false
    }

    private func update(_ item: ExtensionSummary) async {
        guard let client = app.client else { return }
        busy = true
        do {
            struct Updated: Decodable { let updated: UpdateInfo
                struct UpdateInfo: Decodable { let shortCommitHash: String? }
            }
            _ = try await client.call(
                "extension.update",
                args: ["name": .string(item.name)],
                as: Updated.self
            )
            await load()
            showReloadHint = true
            notice = "已更新 \(item.displayName)。"
        } catch {
            notice = "更新失败：\(error.localizedDescription)"
        }
        busy = false
    }

    private func remove(_ item: ExtensionSummary) async {
        guard let client = app.client else { return }
        busy = true
        do {
            struct Deleted: Decodable { let deleted: String }
            _ = try await client.call(
                "extension.delete",
                args: ["name": .string(item.name)],
                as: Deleted.self
            )
            await load()
            showReloadHint = true
        } catch {
            notice = "删除失败：\(error.localizedDescription)"
        }
        busy = false
    }
}
