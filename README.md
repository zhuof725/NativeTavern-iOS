# Native Tavern：SwiftUI + 内置原版酒馆核心

状态：**原版 SillyTavern 核心已在 App 内运行**，并可通过配置的模型 API 生成回复。
世界书、宏、提示词组装、生成请求全部使用上游原始代码。

## 最关键的架构决定：不重写核心

SillyTavern 的「聊天大脑」不在 Node 后端里。真正决定提示词内容的逻辑在前端模块中：

| 能力 | 实际实现位置 |
|---|---|
| 世界书扫描与激活 | `public/scripts/world-info.js`（6,408 行） |
| 宏展开（`{{user}}`/`{{char}}`/`{{roll}}`/变量…） | `public/scripts/macros.js` + `macros/` 宏引擎 |
| 提示词编排 | `public/scripts/openai.js`（7,396 行） |
| 生成流程、回复落盘 | `public/script.js` 的 `Generate()` |

这些逻辑依赖 DOM、jQuery 和大量全局状态。**用 Swift 重写等于写另一个程序**，而且会永久落后于上游。

所以本工程把上游源码原样放进 App，让它照原样运行：

```text
SwiftUI 界面（原生，无 WebView）
  └─ EmbeddedEngine：App 生命周期内启动一次
      └─ Objective-C++ → node_start → NodeMobile.xcframework
          └─ Engine/boot.mjs
              ├─ 原版 server.js（Express 后端，随机回环端口）
              ├─ 原版 public/script.js（完整前端核心，跑在最小 DOM 上）
              └─ 令牌网关：只监听 127.0.0.1，逐次启动随机令牌

SwiftUI → URLSession → 127.0.0.1/engine/rpc → 原版模块
```

## 引擎接口

| 方法 | 作用 | 实际执行者 |
|---|---|---|
| `engine.status` | 运行状态与能力列表 | 引擎 |
| `worldinfo.list/get/create/activate/scan` | 世界书读写与关键词扫描 | `world-info.js` |
| `macro.substitute` | 宏展开 | `macros.js` |
| `character.setName` | 当前角色名 | `script.js` |
| `chat.load` | 写入并打开聊天 | 上游聊天端点 + `getChat()` |
| `prompt.build` | 组装最终提示词 | `openai.js` 的 `prepareOpenAIMessages` |
| `settings.get/update/setSecret` | 模型与参数设置 | 上游设置/密钥接口 |
| `generate.reply` | 调用模型并取回回复 | `script.js` 的 `Generate()` |

`prompt.build` 从核心**当前打开的聊天**组装提示词，不再接受一份独立的消息数组——
两份副本一定会漂移。

## 与原版的差异（全部记录在 `Scripts/patch-core.sh`）

上游源码只改两处，且都是「不要在手机上跑打包器」：

| 文件 | 改动 | 原因 |
|---|---|---|
| `src/middleware/webpack-serve.js` | 存在 `public/lib.bundle.js` 时跳过 Webpack；`webpack` 改为动态导入 | 手机冷启动不应运行 bundler |
| `webpack.config.js` | 不再静态导入 `webpack`（仅用于缓存键） | 同上 |

引擎侧另外做了三件「页面才有的事」，都写在 `Engine/` 里而非改上游：

1. **最小 DOM**（`dom/environment.mjs`）：用 happy-dom 解析 `index.html`，补上页面里存在但实现缺失的构造器。
2. **脚本执行**（`dom/classic.mjs`）：把核心插入的 `<script>` 替换为直接执行模块并派发 `load`，与浏览器行为一致。
3. **回环请求**（`dom/loopback.mjs`）：把页面相对路径指向内置后端，并维护会话与 CSRF；外部网络探测直接返回 503，不访问第三方。

页面扩展（TTS、画廊、翻译等）已从随包的核心中移除：它们是需要页面 DOM 的网页插件，核心不依赖它们。

## 已验证

```sh
npm test     # 10 项，全部通过
```

- **传输层**：握手、令牌校验、拒绝浏览器来源、RPC 错误码。
- **启动**：真实启动原版后端与前端核心，写入世界书 → 激活 → 关键词扫描 → 进入提示词。
- **生成**：用本地模拟模型验证完整链路。引擎调用模型时发送的消息由上游 `openai.js` 组装，
  包含角色卡字段、世界书注入与聊天历史，回复经上游路径写回并返回。

## 还没完成

1. **模型设置界面**：已可用（`ModelSettingsView`），但只覆盖 OpenAI 兼容端点。
2. **角色卡导入**：解析代码已随核心加载，导入 UI 未做。
3. **世界书/预设管理界面**：数据层可用，SwiftUI 界面未做。
4. **依赖裁剪**：`Engine/core/node_modules` 是上游完整依赖树。
5. **真机验收**：云端已完成 Xcode 编译与归档，未在 iPhone 上运行验证。

## 构建

云端（推荐）：

```sh
gh workflow run build-ios.yml -f bundle_id=com.example.nativetavern
```

本地 macOS：

```sh
bash Scripts/fetch-runtime.sh
(cd Engine/core && npm install --omit=dev)
bash Scripts/build-lib-bundle.sh
xcodegen generate
xcodebuild -project NativeTavern.xcodeproj -scheme NativeTavern \
  -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

## 版本锁定

| 组件 | 版本 |
|---|---|
| SillyTavern | `82b64a45c34facbc98ff4b9f33c067d3ccab6a17`（release，2026-11-19） |
| NodeMobile | `digidem/nodejs-mobile` `24.20.0-0`（SHA256 见 `Runtime/node-mobile.lock.json`） |
| 参考实现 | Fish Pocket `8be4c915986c886b4202a6660ecc691185e7ea6d` |

本工程不包含 Fish Pocket 的源码、商标或图标。

## 更新上游

```sh
bash Scripts/sync-core.sh <commit>
```

会重新 vendor 源码、安装该版本声明的依赖、重新打补丁、重建 bundle，然后 `npm test` 应全绿。
补丁锚点找不到时 `patch-core.sh` 会直接报错，不会静默产出错误代码。
