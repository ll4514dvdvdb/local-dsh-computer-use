# 更新记录

## 1.43.2

- 许可证补全：LICENSE 保留原作者 LJL454 的版权行，另加 ll4514dvdvdb and local-dsh-computer-use contributors 一行（MIT 对派生作品的要求：上游声明不能删，自己的改动要能溯源）。
- package.json 补 author（两位署名）与 repository（指向 GitHub 仓库）。
- 仓库改名 dsh-auto-control → local-dsh-computer-use，与包名 @local/dsh-computer-use 对齐，地址 https://github.com/ll4514dvdvdb/local-dsh-computer-use 。

## 1.43.1

- 提示条改成和描边同一个强调蓝（Accent = rgb(56,148,255)）实心底 + 白字 + 细白边，不再用深灰底：它现在一眼就能和桌面上的蓝色描边认成同一套东西。
- 字号基准 15 → **22**（按短边缩放后 2880x1620 上实际 33px），内边距 20/10 → 26/13，距顶 20 → 24。尺寸仍然全部乘 UiScale()，不是写死像素。

## 1.43.0

- 屏幕覆盖层加一条顶部胶囊提示：`DeepSeek Harness 正在操控电脑 · 动鼠标或按任意键停止`。深色半透明底 + 圆角 + 白字，宽度随文本自适应，字号与位置按屏幕短边缩放（1080p 为基准，clamp 0.6–2.6），200% DPI 下不会变糊也不会溢出。写在 `indicator.ps1` 的 `DrawBadge()` 里，和描边、点击环同一次 `UpdateLayeredWindow` 提交，不额外开窗口、不抢焦点。
- 文案写产品名 "DeepSeek Harness" 而不是具体模型名：这个插件可以接别人家的模型，写死 "DeepSeek" 会在那种环境下变成错话。
- `TakeoverMoveThreshold` 默认值 500 → **1200** device units。实测用户正常用电脑时，两次请求之间的鼠标位移常在 1000 上下（一次 `computer_control` 看到 1673），500 会把"人只是正常用电脑"误判成接管。按键仍然立即判定。
- `indicator.ps1` 的默认文案在 C# 源码里（该文件带 UTF-8 BOM，PowerShell 5.1 能正确读出中文）；`worker.ps1` 必须无 BOM，所以**不要**把中文文案放进 worker 的字符串里，否则会以 GBK 解成乱码。
## 1.42.0 — 2026-11-08

**新增：屏幕上看得见"AI 正在操作"（视觉指示），以及截图之间的"看起来变了没有"（感知差异）。**

- **视觉指示（`backend/indicator.ps1`）**：独立进程画的点击穿透覆盖层，`UpdateLayeredWindow` 32bpp ARGB，不动输入、不抢焦点、不进任务栏。三样东西：桌面四边的蓝色渐变描边、指针周围的同心圆光晕、每次点击位置的扩散环。**所有尺寸按屏幕短边比例算**（`min(宽,高)/1080`，夹在 0.6–2.6），所以 1366×768 与 3840×2160 上观感一致，不是写死的像素值。进程跟随 worker 生命周期（轮询 `-ParentPid`，worker 死了自己退出），状态走临时目录里的小文件（`active=` 戳 + `click=at,x,y` 行）。配置 `DSH_COMPUTER_USE_INDICATOR=0` 关闭。
- **截图感知差异**：`Do-Screenshot` 每次顺手把图缩到 64×36 网格算签名，与同一目标上一帧比，输出 `change: {known, changed, cells, total, score, ...}`。判据是**变化格数**（单格平均色差 ≥ 12 算一格变化，≥ 12 格算"变了"）而不是平均分——2304 格里改一行字只把平均分推到 1.04，平均分会被稀释到看不出。和已有的字节级 `unchanged` 互补：字节不同但画面没变（光标闪烁、秒表跳秒）时它说"重看没用"。
- **DPI**：`indicator.ps1` 先 `SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)` 再加载 WinForms，`Show()` 之后用 `SetWindowPos` 按物理像素铺满虚拟屏幕（只设 `AutoScaleMode.None` 不够，WinForms 会把窗口缩回设计尺寸）。
- **测试**：`test-indicator-e2e.ps1`（spawn worker → 读 ready → 发 click → 断言 indicator 进程起来、状态文件有 `active` 与对应坐标的 `click` 行、worker 退出后进程消失）；`test-perceptual.ps1` 覆盖签名与格数判据；确定性套件统一 `DSH_COMPUTER_USE_INDICATOR=0`，不让测试弹窗口。
## 1.41.0 — 2026-11-08

**新增：人一碰键鼠就把桌面交还给他（物理输入接管），外加 `computer_control` 控制状态查询和三级推回强度。**

- **物理输入接管**：worker 装 `WH_KEYBOARD_LL` / `WH_MOUSE_LL`，按 `LLKHF_INJECTED` / `LLMHF_INJECTED` 位把"本插件自己 SendInput 出来的输入"与"真人"分开。发输入前检查，命中就抛 `[USER_TAKEOVER]`；bridge 把它报成 `USER_TAKEOVER` 错误码，`internal/failures.mjs` 给出"先看屏幕、别连着重试"的处理建议。判据是"物理输入时间戳新于本请求开始"或"物理鼠标移动累计 ≥ 500 device units"，前者的时间戳用 `Stopwatch` 单调钟（Add-Type 编译在 .NET 4.0 参考程序集上，`Environment.TickCount64` 不可用）。
- **`computer_control` 工具**：一次读出两件独立的事——接管状态（`mode` / `enabled` / `ready` / `keyboard` / `mouse` / `moveThreshold` / `lastPhysicalAgeMs` / `movedSinceBaseline` / `physicalEvents`）与租约状态（`owns` / `held` / `owner` / `idleMs` / `lastAction`）。带 `mode` 参数时它同时也是切换开关。
- **三级推回**：`off` 从不拒绝但照常统计；`input`（默认）在发输入前拒绝；`all` 连 `wait` 分片睡眠里也拒绝。配置走 `DSH_COMPUTER_USE_TAKEOVER`（0 关闭）、`DSH_COMPUTER_USE_TAKEOVER_MOVE`（默认 500）、`DSH_COMPUTER_USE_TAKEOVER_MODE`（off/input/all）。
- **`physicalEvents` 计数**：时间戳只能回答"最近一次是什么时候"，回答不了"这 80ms 里有没有真事件"。C# 侧加了 `PhysicalEvents`，测试靠它把"用户真的在操作"和"注入被正确过滤"分开——否则用户一动鼠标，测试就只能报假失败。
- **测试**：`test-takeover.ps1`（钩子 + worker 行协议 + 注入期间 wait）；`lifecycle-test.mjs` 与其它确定性套件默认 `DSH_COMPUTER_USE_TAKEOVER_MODE=off`，因为"用户碰鼠标就打断"正是这些套件不能容忍的，守卫本身由 takeover 套件单独覆盖。

## 1.40.2 — 2026-10-22

**修复：一次大尺寸 PNG 截图会让所在会话永久不可用。**

宿主对附件做归一化时会把超限的 PNG 重编码（带 alpha → WebP，否则 JPEG），插件过去把**入参**
声明的 `mediaType` 写进会话记录，于是记录成了"PNG 标签 + WebP 实体"，`bytes` / `width` /
`height` 却是归一化后的真值。宿主每轮重放历史时按字节复核 ref，判 `ATTACHMENT_CORRUPT`：

```
Stored attachment metadata does not match its reference.   (code: UNKNOWN)
```

失败发生在请求组装阶段（`step` 停在 1），模型一次都没被调用；新建会话正常。

- `internal/capture.mjs`：`admitCapture()` 整条 ref 透传 —— `mediaType` 取 `ref.mediaType`，
  `bytes` / `width` / `height` / `originalDimensions` 全部来自同一个 ref，不再与入参混用。
- `internal/tool-contracts.mjs`：`IMAGE_VALUE_SCHEMA` 增加可选的 `originalDimensions`
  （`additionalProperties: false`，不声明就会被宿主判为未声明属性）。
- `schema-test.mjs`：新增 4 条断言，用一个"会改格式"的假存储把这条路径钉死；把修复退回旧写法
  时测试立刻失败并打印 `image/png vs image/webp`。

**已经写坏的会话不会自愈**：日志里那条 image block 仍会被每轮重放。处置办法是把它记的
`mediaType` 改成落盘对象的真实格式（看对象头魔数：`89 50 4E 47`=PNG、
`52 49 46 46 … 57 45 42 50`=WebP、`FF D8 FF`=JPEG），或弃用该会话。

**修复：以 `link:` 安装后没有「电脑操作」按钮。**

`dsh plugin add` 装出来的是 `link:`，模块留在解压目录（例如 `D:\DSH-Plugins\...`）。插件过去
用静态 `import '@deepseek-ai/dsh-tools'` 取 `defineTool`，Node 会从那个目录逐级向上找
`node_modules` —— 应用自带的包在 `<app>\resources\app\dsh\node_modules`，不在这条路径上，
于是整行导入失败：

```
dsh: warning: 1 entry did not activate
computer-use (@local/dsh-computer-use): failed to import: Error [ERR_MODULE_NOT_FOUND]:
Cannot find package '@deepseek-ai/dsh-tools' imported from D:\DSH-Plugins\...
```

宿主本身一切正常（`tools` 行是它自己的），所以界面上只有"装好了但没有芯片"，没有任何报错。
过去的临时办法是往插件目录里塞一份宿主同版本的 `dsh-tools` / `cordis` / `dsh-llm` /
`dsh-sandbox` / `dsh-scope`，但那是把宿主版本抄进插件，升级必然错位。

- 新增 `internal/host-packages.mjs`：先按普通说明符解析（装在 profile 里时正确），失败则按
  **运行中应用的绝对路径**导入 `<exe>\resources\app\dsh\node_modules\@deepseek-ai\...`。
  以文件 URL 导入入口后，它自己的依赖（`dsh-llm`、`cordis`、`dsh-sandbox`…）由 Node 从应用
  目录解析，所以插件旁边**不需要任何 node_modules 副本**。
- `index.js`：静态 import 改为顶层 `await importHostModule('@deepseek-ai/dsh-tools')`。
- `internal/app-launch.mjs`：不再自己 import `defineTool`，改用主插件传入的那份；缺失时只关掉
  `app_launch` / `app_env_audit` 两个工具，不再拖垮整行。
- `internal/schema-visibility.mjs` 的 `dsh-scope` 解析本来就是 try/catch 降级，保持不动。

验证：把包解压到一个**没有 node_modules** 的目录、以 `link:` 装进干净 profile —— 修复前
`/computer-use/status` 返回 404（行未激活），修复后返回 200 且 `registrationFailures: 0`。

**与插件解压到哪一行无关。** 解析锚点始终是**运行中的应用**，不是插件目录：命令行
（`<app>\resources\app\dsh\node_modules\...`）→ `process.execPath` → `%LOCALAPPDATA%` /
`%ProgramFiles%` → `DSH_APP_MODULES`。实测三种刁钻路径全部正常（HTTP 200、
`registrationFailures: 0`）：

| 解压位置 | 结果 |
| --- | --- |
| `E:\临时 目录\插件 安装位置\dsh-computer-use`（空格 + 中文） | 200 |
| `C:\Users\<用户>\Downloads\插件包\dsh-computer-use-1.40.2\dsh-computer-use`（深层） | 200 |
| `E:\cu #1\dsh-computer-use`（`#`） | 200 |

`/computer-use/status` 的 `runtime.host` 新增 `hostPackages`，直接写出这份
`@deepseek-ai/dsh-tools` 来自哪里、是什么版本、是否来自安装目录：

```json
"hostPackages": {
  "tools": "C:\\...\\resources\\app\\dsh\\node_modules\\@deepseek-ai\\dsh-tools\\package.json",
  "toolsVersion": "0.2.1-rc.2",
  "fromApplication": true
}
```

顺带把 `runtimeVersion` 也修好了：`link:` 安装下 `import.meta.resolve` 必然失败，过去这里显示
`unknown`；现在同一个解析器回落到安装目录读 `dsh-app-boot` 的清单。

**安装入口**：新增 `setup.mjs`（一条命令完成安装 + 清理 + 复核）、`install-and-repair.cmd`
与 `fix-profile-links.cmd`（双击即可）。

**安装渠道澄清：npm 上那两个名字都不是本项目。**

有用户用插件框"输包名"安装，装到的是 npm 上的 `dsh-computer-use@0.3.1`——**另一个作者的插件**
（仓库 `988hj7tczd-oss/dsh-computer-use`），所以看起来"包体还是老的"。本项目的名字是
`@local/dsh-computer-use`，`@local` 是不可发布的占位作用域，npm 上并不存在。

| npm 上的名字 | 实际是什么 |
| --- | --- |
| `dsh-computer-use` | 别人的插件，0.3.1，2026-09-10 最后更新 |
| `@deepseek-ai/dsh-computer-use` | 官方 `deepseek-harness` 的 provider 注册辅助包 0.1.6-alpha.1 |
| `@local/dsh-computer-use` | 本项目，未发布 |

- Release 多带一个可直接安装的 tarball：`dsh plugin add <路径>\local-dsh-computer-use-1.40.2.tgz`
  （实测：安装后 `/computer-use/status` 返回 200、`registrationFailures: 0`）。
- 新增 `tools/publish-npm.mjs`：要发布到自己名下的包时用它把名字**一次性改写一致**（manifest、
  bundle patch、presets、doctor、文档），只打包不发布，最后打印 `npm publish` 命令。
  用 `--name dsh-computer-use-ljl454` 实测：改写 19 个文件后打包 888 KB，装进干净 profile
  后行正常激活（`fromApplication: true`）。
- `runtime.host.hostPackages.fromApplication` 改为按**路径**判断（是否落在
  `<app>\resources\app\dsh\node_modules`），不再依赖"走了哪条解析分支"——装在 profile 里时
  宿主包也可能由适配层解析到应用目录，旧写法会误报 `false`。



## 1.40.1 — 2026-10-22

**修复：装完之后 DeepSeek Harness 起不来。**

1.39.x 与 1.40.0 都把 `@deepseek-ai/dsh-tools` 声明成 peer（1.39 是 `"*"`，1.40.0 是
`>=0.2.1-rc.2 <0.3.0`，两者都是 `optional: false`）。包管理器据此会在用户的 profile 里落一份
实体副本：

```
<profile>\node_modules\@deepseek-ai\dsh-tools\      ← 包管理器装的
```

而宿主的 `tools` 这一行**优先从 profile 解析**。副本与桌面版版本一旦不一致，loader 直接禁用
该行（`dsh: disabling profile plugin row "tools" ...`），所有注入 `tools` 的 row 一起挂起，
其中 `agent-loop` 是 required：

```
The application could not start or stopped unexpectedly.
agent-loop (required)  tools
tool-working-directory tools
...
```

界面上这张表**不点名任何插件**，所以很难查。1.39 的 `"*"` 在 npm 上解析到 `latest`
（当时是 `0.0.1-rc.1`），因此几乎必然触发。

- `package.json`：删除 `peerDependencies` / `peerDependenciesMeta` 中的 `@deepseek-ai/dsh-tools`
  与 `@deepseek-ai/dsh-scope`（后者从未被 `import`）。宿主的包由 loader 的解析适配层提供，
  不需要 profile 里有副本 —— 在"profile 里完全没有该包"的干净环境上实测通过。
- `index.js`：`apply()` 增加只读自检，profile 若自带一份 `dsh-tools` 会报到
  `runtime.profileShadow`，并在日志里给出修复命令。
- 新增 `tools/fix-profile-links.ps1`：把实体副本换成指向安装目录的 junction（幂等），
  并报告"被写进 `package.json` 依赖树"这种安装删不掉的情况。

**升级的用户不需要额外动作**：`dsh plugin add` 内部的 `pnpm install` 会把那份已不在依赖树里的
副本移到 `node_modules\.ignored\`。实测一个 `tools` 行已被禁用、完全起不来的 profile，重跑
一次安装命令即恢复启动。

## 1.40.0 — 2026-10-22

把 1.39.5 已确认的安装/诊断问题修掉，不加新工具：

- 重复挂载在注册任何工具/路由之前被拒绝（`DUPLICATE_INSTANCE`）；
- manifest 声明 `engines.dsh`，peer 范围不再写 `*`；
- `doctor` 分离线/在线两层，缺 `release-input.ps1` 或缺发行清单不再假通过；
- 全发行 `releaseBuildId` 覆盖 host / client / internal / patch / worker，不再只看 `worker.ps1`；
- PowerShell 候选按 PATH + PATHEXT 真正解析；
- 三个任务预设拆成独立可选 bundle（`presets/`），核心安装不再依赖文档/分析运行时；
- 浏览器底层缺全局 WebSocket 时报 `WEBSOCKET_UNAVAILABLE`，不再裸 `ReferenceError`。

## 1.39.5 — 2026-10-18

预设加载、重复挂载、芯片时序与工具可见性的一组修复。

