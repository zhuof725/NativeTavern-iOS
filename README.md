# Native Tavern：SwiftUI + 内置原版酒馆核心

状态：**原版 SillyTavern 核心与整套界面都在 App 内运行**。
界面就是酒馆自己（系统浏览器标签页指向 App 内的服务端），因此扩展、斜杠命令、
群聊、人设、主题、备份、模板与角色编辑器全部可用；Swift 只负责启动、
网关与失败诊断。

## 最新构建

| 项 | 值 |
|---|---|
| IPA | `NativeTavern-unsigned.ipa`，约 109 MiB（0.3.1） |
| 提交 | `3cc9a96` |
| 构建记录 | [GitHub Actions](https://github.com/zhuof725/NativeTavern-iOS/actions/runs/45025688562) |
| 签名 | 未签名，安装前需自签 |
| 设备 | iPhone ARM64，iOS 17+ |
| 验证 | 结构、SHA256 校验通过；**未在真机运行** |

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
| `settings.snapshot` | 原生设置页的完整快照 | 核心的活动设置对象 |
| `generate.reply` / `chat.send` | 调用模型并取回回复 | `script.js` 的 `Generate()` |
| `character.list/get/create/edit/delete/import/select` | 角色库 | 上游角色端点 + 角色卡解析器 |
| `chat.list/read/open/new/delete/rename/save` | 聊天记录 | 上游聊天端点 + `getChat()` / `doNewChat()` |
| `message.edit/delete/swipe` | 消息操作与重新生成 | 核心聊天对象 + `Generate('swipe')` |
| `preset.list/apply` | 对话预设 | 上游预设文件与 `settingsToUpdate` |
| `prompt.list/toggle` | 提示词顺序 | `PromptManager` 自己的顺序表 |

`prompt.build` 从核心**当前打开的聊天**组装提示词，不再接受一份独立的消息数组——
两份副本一定会漂移。

## 与原版的差异

上游源码只改两处，都在 `Scripts/patch-core.sh` 中，且都是「不要在手机上跑打包器」：

| 文件 | 改动 | 原因 |
|---|---|---|
| `src/middleware/webpack-serve.js` | 存在 `public/lib.bundle.js` 时跳过 Webpack；`webpack` 改为动态导入 | 手机冷启动不应运行 bundler |
| `webpack.config.js` | 不再静态导入 `webpack`（仅用于缓存键） | 同上 |

引擎侧另做了几件「页面才有的事」，都写在 `Engine/` 里而不是改上游：

1. **最小 DOM**（`dom/environment.mjs`）：用 happy-dom 解析 `index.html`，补上页面里存在但 Node 缺失的构造器，并把文档标记为 `complete`。
2. **脚本执行**（`dom/classic.mjs`）：核心插入 `<script>` 时直接执行对应模块并派发 `load`，与浏览器行为一致。
3. **回环请求**（`dom/loopback.mjs`）：把页面相对路径指向内置后端并维护会话与 CSRF；对外部探测直接返回 503，不访问第三方。
4. **模块解析**（`dom/loader.mjs`）：把 `/scripts/xxx.js` 这类页面路径映射到实际文件，把 `../lib.js` 映射到预构建 bundle。
5. **可写工作目录**（`boot.mjs`）：上游把 `backups/`、默认头像和全局扩展目录解析为工作目录相对路径。
   iOS 的 App 包是只读的，所以服务端在一个位于数据目录下的可写副本里运行；`server.js` 自己的
   `process.chdir(serverDirectory)` 被重定向到该目录，静态文件仍从包内读取。

两处无头环境特有的初始化问题也已显式处理，不靠运气：

- **提示词顺序**：设置重载后，管理器会拿到用不同哨兵 id 记录的 prompt order，导致聊天历史被静默丢弃。`restorePromptOrder()` 在重载后恢复。
- **页面扩展**：随包核心只保留 `regex`（其 `engine.js` 被核心直接导入）。其余扩展靠注入 `<script>` 激活，无浏览器时永远不会完成，会卡住首次加载。

## 已验证

```sh
npm test     # 12 项，本地 Node 22 与 GitHub macOS/Node 24 均通过
```

- **传输层**：握手、令牌校验、拒绝浏览器来源、RPC 错误码。
- **启动**：真实启动原版后端与前端核心，写入世界书 → 激活 → 关键词扫描 → 进入提示词。
- **生成**：用本地 OpenAI 兼容模拟服务验证完整链路。请求中的消息由上游 `openai.js` 组装，
  包含角色卡字段、世界书注入与聊天历史；回复经上游路径写回并返回。
- **管理接口**：角色创建/编辑/删除/导入/换头像、聊天新建/重命名/删除/读取、
  消息编辑/删除/滑动、世界书条目增删改、预设应用、提示词开关、设置快照。

## 原生界面覆盖

| 区域 | 能力 |
|---|---|
| 角色 | 列表、搜索、新建、编辑、删除、导入 PNG/JSON/CHARX、更换头像 |
| 聊天 | 聊天列表、新建/删除/重命名、发送、停止、重新生成、左右滑动、编辑与删除消息 |
| 世界书 | 列表、启用/停用、删除、条目增删改（关键词、常驻、顺序、深度、概率…） |
| 预设 | 应用对话预设、采样参数、提示词顺序开关、最终提示词检查 |
| 设置 | 多家模型服务、API 密钥、用户名称、人设、引擎状态与日志 |

## 还没完成

1. **真机验收**：已完成云端编译与归档，**未在 iPhone 上运行验证**。这是当前最大的未知。
2. **群聊**：核心的群聊模块已加载，原生界面尚未接入。
3. **扩展/正则/TTS/画图**：这些属于酒馆的扩展生态，目前只在核心内可用，没有原生入口。
4. **体积**：105 MiB 中仍有相当部分来自上游依赖树；`Scripts/trim-core.sh` 记录了已裁剪项。

## 构建

云端（推荐）：

```sh
gh workflow run build-ios.yml -f bundle_id=com.example.nativetavern
```

工作流依次：安装原版依赖 → 安装引擎脚手架依赖 → 裁剪 → 预构建 `lib.bundle.js` → 运行测试 →
Xcode 归档 → 打包未签名 IPA。任何一步失败都不会产出 IPA。

本地 macOS：

```sh
bash Scripts/fetch-runtime.sh
bash Scripts/install-engine-deps.sh
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
补丁锚点找不到时 `patch-core.sh` 直接报错，不会静默产出错误代码。
