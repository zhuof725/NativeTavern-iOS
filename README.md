# Native Tavern：SwiftUI + 内置原版酒馆核心

状态：**原版 SillyTavern 核心已在 App 内运行**，世界书、宏、提示词组装使用上游原始代码。
模型生成与角色卡导入尚未接入。

## 最关键的架构决定：不重写核心

SillyTavern 的「聊天大脑」不在 Node 后端里。真正的逻辑在 `public/script.js` 及其导入的前端模块中：

| 能力 | 实际实现位置 |
|---|---|
| 世界书扫描与激活 | `public/scripts/world-info.js`（6,408 行） |
| 宏展开（`{{user}}`/`{{char}}`/`{{roll}}`/变量…） | `public/scripts/macros.js` + `macros/` 宏引擎 |
| 提示词编排 | `public/scripts/openai.js`（7,396 行） |
| 生成流程 | `public/script.js` 的 `Generate()` |

这些逻辑依赖 DOM、jQuery 和大量全局状态。**用 Swift 重写它们等于写另一个程序**，而且会永久落后于上游。

所以本工程的做法是：把上游源码原样放进 App，让它照原样运行。

```text
SwiftUI 界面（原生，无 WebView）
  └─ EmbeddedEngine：App 生命周期内启动一次
      └─ Objective-C++ → node_start → NodeMobile.xcframework
          └─ Engine/boot.mjs
              ├─ 启动原版 server.js（Express 后端，随机回环端口）
              ├─ 启动原版 public/script.js（完整前端核心，跑在最小 DOM 上）
              └─ 令牌网关：只监听 127.0.0.1，逐次启动随机令牌

SwiftUI → URLSession → 127.0.0.1/engine/rpc → 原版模块
```

## 已实测可用的能力

在引擎内（Linux Node 22）端到端验证通过：

1. **世界书**：通过 API 写入条目 → 按 UI 同一入口激活 → 关键词扫描命中 → 内容进入最终提示词。
2. **宏**：`{{user}}`、`{{char}}` 由上游宏引擎解析（`User meets Seraphina`）。
3. **提示词组装**：`openai.js` 的真实 pipeline 产出完整消息序列，含角色描述、世界书注入、聊天历史。

回归测试：

```sh
npm test        # 8 项传输层 + 1 项完整启动（真实启动原版后端与前端核心）
```

## 与原版的差异（全部记录在 `Scripts/patch-core.sh`）

上游源码只改两处，且都是「不要在手机上跑打包器」：

| 文件 | 改动 | 原因 |
|---|---|---|
| `src/middleware/webpack-serve.js` | 存在 `public/lib.bundle.js` 时跳过 Webpack；`webpack` 改为动态导入 | 手机冷启动不应运行 bundler |
| `webpack.config.js` | 不再静态导入 `webpack`（仅用于缓存键） | 同上 |

`lib.bundle.js` 由 `Scripts/build-lib-bundle.sh` 用 esbuild 预构建，与上游 Webpack 产物用途相同。
若上游文件结构变化，`patch-core.sh` 会明确报错而不是静默产出错误代码。

## 还没完成

1. **模型生成**：`prompt.build` 已产出正确的请求消息，但还没有把请求发给模型、处理流式回复、把回复写回聊天。
2. **角色卡导入**：PNG/CHARX/JSON 解析在上游 `char-data.js` 中已加载，但导入 UI 和文件选择未接。
3. **预设与世界书管理界面**：数据层已通，SwiftUI 界面未做。
4. **依赖裁剪**：`Engine/core/node_modules` 仍包含上游全部依赖，其中相当一部分在实际使用中不会被加载。
5. **真机验收**：云端已完成 Xcode 编译与归档，但未在 iPhone 上运行验证。

## 首次启动较慢的原因

原版后端首次启动会复制内容模板并按需加载大量模块。之后启动只是读取已有数据。
如果启动明显变慢，先看 `Engine/core/data/` 是否已初始化。

## 构建

云端（推荐）：

```sh
gh workflow run build-ios.yml -f bundle_id=com.example.nativetavern
```

工作流会安装原版依赖、预构建 `lib.bundle.js`、运行测试，然后归档并打包未签名 IPA。

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

会重新 vendor 源码、安装该版本声明的依赖、重新打补丁、重建 bundle，然后 `npm test` 应该全绿。
