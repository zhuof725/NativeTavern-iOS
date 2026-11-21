# GitHub 云端编译与 IPA 打包

工作流：`.github/workflows/build-ios.yml`。使用标准 macOS 托管 runner，仅手动触发，不因每次 push 自动重复构建。

## 构建内容

1. 安装 Node 并运行本地通信与启动测试。
2. 核对运行时 SHA256，下载锁定的 NodeMobile 框架。
3. 通过 XcodeGen 生成 SwiftUI 工程。
4. 用 Xcode 为 `generic/platform=iOS` 归档 ARM64 设备应用。
5. 检查应用、NodeMobile 与引擎入口后封装 `Payload/*.app` 为 IPA。
6. 校验 IPA 布局、ARM64 可执行文件和 ZIP CRC，并上传构建产物。

GitHub Actions 本身使用核验过的完整提交 SHA，不使用可移动主分支作为 action 版本。

## 触发与下载

在仓库 Actions 中选择 **Build unsigned iOS IPA → Run workflow**，保持默认 Bundle ID 或填写自己的合法标识。

成功后，在运行页面的 Artifacts 中下载 **NativeTavern-unsigned-ipa**。外层 ZIP 包含：

- `NativeTavern-unsigned.ipa`
- `BUILD-INFO.json`：来源提交、Xcode 版本、原型状态及签名状态
- `SHA256SUMS`

构建日志另存为 `NativeTavern-build-log`。产物默认保留 7 天，源码则留在仓库。

## 签名与功能边界

**这是待签名 IPA，不能当作已签名安装包直接安装。** 工作流不需要也不会导入 Apple 私钥、证书、描述文件或 App Store Connect 密钥。若之后改为开发者签名、Ad Hoc 或 TestFlight，必须另行配置相应授权与 GitHub Secrets，不应把凭据写进仓库或聊天。

打包的应用仍是当前 M0 原生架构原型。酒馆角色卡、聊天、提示词编排、世界书和生成核心没有因此自动完成。构建凭据明确标记 `sillyTavernCoreIntegrated: false`。

`Scripts/validate-ipa.py` 也可以在本地用 Python 检查下载文件；这种检查不能替代重签后的真机启动与功能测试。
