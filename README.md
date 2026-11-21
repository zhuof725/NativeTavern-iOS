# Native Tavern：SwiftUI + App 内本地运行时

状态：M0 原生架构接入原型，**不是已移植完成的 SillyTavern，也不是可安装成品**。

## 最新要求

2026-11-21 用户明确：酒馆引擎放进 iPhone App 内，不依赖电脑或外部酒馆服务器；主界面必须使用 SwiftUI 原生实现。参考 Fish Pocket 的嵌入式运行时模式，不再把 Tauri/WebView 主界面作为开发主线。

- `../TauriTavern/` 及其首批补丁完整保留，仅作为数据、接口和行为对照。
- 本目录是独立的新原生工程，不包含 Fish Pocket 源代码、商标或图标。
- 不依赖外部酒馆后端，不等于本地运行大语言模型。将来调用在线模型 API 时仍需联网；离线模型推理尚未实现。

## 架构

```text
SwiftUI 原生界面
  └─ EmbeddedEngine：App 生命周期内仅启动一次
      └─ Objective-C++ → node_start → NodeMobile.xcframework
          └─ Engine/boot.mjs → App 内本机通信宿主

SwiftUI → URLSession → 127.0.0.1 临时端口 → 本地引擎接口
                                      └─ 原版核心适配：尚未接入
```

`127.0.0.1` 是同一设备内的回环通信，不是连接电脑、云服务或其他设备。通信宿主只绑定此地址；每次启动生成新的随机令牌，以带本次启动 UUID 的私有文件交付。Swift 侧拒绝外部主机、过期启动信息和 HTTP 重定向。没有远程后端兜底选项。

NodeMobile 选择 `digidem/nodejs-mobile` 的 `24.20.0-0`，与参考项目所选版本一致；已向其官方 GitHub 发布 API 核对 SHA256。这里只记录锁定摘要与获取脚本，**尚未下载、链接或在手机运行此框架**。没有移植参考项目的根文件系统、Git、Python 或其他原生适配组件。

## 本次真正完成了什么

- SwiftUI 原生角色页、聊天页和运行状态页；前两页明确显示“尚未接入”，没有虚构角色或模拟聊天。
- App 内专用线程、单次 Node 初始化、连续 argv 内存及设备 CPU 能力保护的接入代码。
- 原生客户端的回环地址白名单、会话令牌、请求 ID 与协议版本验证，以及禁止自动重定向。
- 使用 Node 内置模块实现的本机通信宿主与启动信息发布。
- 11 项可在现有 Linux Node 环境运行的行为测试，包括真实子进程启动、私有握手文件与本地 RPC 往返；全部通过。

当前唯一实现的 RPC 是 `engine.status`。它明确返回 `sillyTavernCoreReady: false`。调用聊天等未接入方法返回 `501 / METHOD_NOT_IMPLEMENTED`，不会用模型直连或假回复冒充原版引擎。

## 还没有完成什么

1. 原版 SillyTavern 后端尚未打包到本工程。
2. 世界书、宏、正则、预设、提示词编排等逻辑仍需从原版前端 JS 中抽离；原版 `public/script.js` 的 `Generate()` 与 `public/scripts/world-info.js` 的 `getWorldInfoPrompt()` 证明这些不只是 Node 后端功能。
3. 角色卡导入、聊天保存、模型生成、流式回复、插件及后台生命周期尚未接入。
4. 依赖 DOM/jQuery 修改页面的原版前端扩展不能直接修改 SwiftUI。此类扩展必须单独适配；当前主界面没有 WebView，也不承诺任意网页扩展原样工作。
5. NodeMobile 不会让 iOS 自动获得桌面的任意子进程、系统命令、原生插件或文件访问能力。
6. 未运行 Swift 编译、XcodeGen、Xcode、模拟器或真机测试，没有 IPA。此前 Tauri 分支的 451 项通过结果不能算作本原生工程的测试结果。

## 在当前环境验证

需要 Node 22 或以上，无第三方 npm 依赖：

```sh
npm test
```

JS 在本机 Node 22.23.4 上验证，不能等同于在 iPhone 的 NodeMobile 24 上验证。Xcode 工程描述另做 YAML 语法检查；不等于 XcodeGen 生成或编译成功。

## macOS 上的后续构建入口（尚未实际验收）

初始目标设为 iPhone / iOS 17.0+，尚未确定用户的设备系统版本。

需要完整 Xcode、Node、XcodeGen，以及真实安装时的签名配置：

```sh
bash Scripts/fetch-runtime.sh
xcodegen generate
xcodebuild -project NativeTavern.xcodeproj -scheme NativeTavern \
  -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

获取脚本校验锁定的官方摘要，且不会静默替换已有框架。不要把模拟器构建等同于已签名真机 App；需要在实际设备检查 Node 启动、CPU 能力判断、ATS 回环访问、前后台切换及数据恢复。

## 迁移顺序

M0 是当前通信和生命周期基础；随后应先完成角色卡与聊天数据的真实读写，再接提示词/世界书/宏/预设的可测试核心和模型生成，最后逐个适配具体扩展。保持 SwiftUI 主界面，不把网页整体嵌回去冒充原生迁移。

参考源码版本：Fish Pocket `8be4c915986c886b4202a6660ecc691185e7ea6d`；SillyTavern 对照 `82b64a45c34facbc98ff4b9f33c067d3ccab6a17`。
