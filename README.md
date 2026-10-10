# AppBind

为每个 App 绑定你的操作。Raycast 管规则，Swift Helper 提供取点、快捷键录制及显式启动的后台服务。

**后台服务运行时，已启用规则可能产生真实点击。保存规则不会自动启动服务。** 使用「AppBind Background Service」查询、启动、停止及重载。没有安装登录项或自动申请系统权限。旧 stdin `execute` 仍拒绝执行；`dry-run` 仍仅算坐标、不点击。后台执行的实际兼容性与权限行为需要人工验收，不能把测试通过视为所有窗口均安全可点。

## 设计与工程契约

- [实施计划与实际状态](<docs/plan.md>)
- [v1 配置/协议/错误码及安全契约](<docs/CONTRACT.md>)
- [完整示例配置](<examples/config.v1.json>)（示例 Bundle ID 必须改成自己的目标 App）

## 环境

开发机：macOS 26.6.2 arm64，Swift 6.4，Node.js 22.22.0 / npm 10.9.4。Swift 部署目标 macOS 13；尚未在 macOS 13 或 Intel 运行验证。需要 Xcode Command Line Tools，Raycast UI 验收需要安装 Raycast。

## 安装

本扩展由 Raycast 扩展（`raycast/` 子目录）与 Swift Helper（`helper/` 子目录）两部分组成，需要分别准备。**仅支持 macOS**：快捷键监听、取点与点击安全校验依赖 macOS 原生辅助功能与输入监控能力，扩展清单也声明 `platforms: ["macOS"]`（[扩展清单](<raycast/package.json>)）。

### 本机安装 Release（推荐日常使用）

先按下文构建 Swift Helper，并确保 Raycast 已启动。若终端正在运行 `npm run dev`，先按 **Ctrl+C** 停止开发监听，避免它覆盖 release 安装。

从仓库根目录执行：

```sh
cd raycast
npm ci --ignore-scripts --cache .npm-cache
npm run install:release
```

`install:release` 会依次：

1. 在隔离的临时目录构建 release，排除快捷键实验、Helper Status、Dry-Run Action、日志查看及调试日志写入实现，保留开发源码。
2. 检查产物没有混入调试入口，并输出到 `dist-release/`。
3. 通过 Raycast CLI 将 release 写入当前用户的本机扩展目录，替换同名 AppBind 扩展。
4. 发送 CLI `build-success` 通知，请 Raycast 重新注册命令列表。仅写入构建文件不足以保证搜索列表更新；通知已发送也不等于 GUI 已确认刷新。

安装后关闭 Raycast 搜索窗口再重新搜索 AppBind，应仅有 **Create Binding、Manage Bindings、AppBind Background Service** 三个命令。不需要再执行 `Import Extension`，也不需要保持开发进程运行。**直接导入原始 `raycast/` 源码目录不是本项目的 release 安装流程**：开发清单仍包含调试命令。

首次安装后，在 AppBind 偏好设置中将 **Absolute Helper Path** 设为本机 Helper 的绝对路径，并按下文完成辅助功能与输入监控授权。该命令**不构建 Helper、不删除规则配置、不授予权限、不启动或重启后台服务，也不发布到 Raycast Store**。

| 命令（在 `raycast/` 中执行） | 用途 |
|---|---|
| `npm run build` / `npm run build:release` | 只构建 release 到 `dist-release/`，不安装 |
| `npm run install:release` | 构建、检查并安装本机 release，通知 Raycast 更新命令列表 |
| `npm run build:dev` | 只构建含调试功能的版本到 `dist/` |
| `npm run dev` | 安装/运行开发模式并监听源码变化，保留调试命令 |

**更新**：拉取新源码后重跑 `npm run install:release`；仅扩展 UI 更新无需重启 Helper。若同时重新编译了 Helper，安装完成后在 **AppBind Background Service → Cmd+K → 重启后台服务** 中加载新版程序。“重载已保存的规则”不能替代程序重启。

**仍看到调试命令时**：先确认开发监听已停止，再重跑 `npm run install:release`，检查是否报告安装或注册通知失败；关闭搜索窗口重试，必要时退出并重新打开 Raycast。不要通过重新导入原始源码目录来修复 release 命令列表，也不要删除规则数据。

脚本实现见 [build-release.mjs](<raycast/scripts/build-release.mjs>)，命令定义见 [扩展清单](<raycast/package.json>)。

### 手动安装到其他 Mac（源码 / ZIP 分发）

未上架 Raycast Store 时，可以把**源码**分发给其他 Mac（git 仓库地址或 ZIP 压缩包），对方按以下步骤手动导入安装。分发的是源码，不是编译产物。

1. **前置要求**：已安装 [Raycast](https://www.raycast.com)；Node.js（`node -v` 可验证；本项目按 Node 22 验证，见 [扩展环境说明](<raycast/README.md>)；没有 Node 时 `brew install node` 或从 [nodejs.org](https://nodejs.org) 下载）；Xcode Command Line Tools 提供 Swift 6 编译器（`swift --version` 可验证；没有时运行 `xcode-select --install`）。Helper 部署目标 macOS 13+，开发机为 macOS 26.6.2 arm64，macOS 13 / Intel 尚未验证（见上「环境」节）。
2. **获取源码**：`git clone` 仓库，或解压收到的 ZIP。**放到一个长期保留的目录**（如 `~/AppBind`）：后续的导入、重新构建和更新都基于这份源码，不要放在「下载」等会被清理的位置。压缩包应排除 `node_modules/`、`dist/`、`dist-release/`、`.build/`、`.cache/`、`.npm-cache/` 等构建产物目录（[`.gitignore`](.gitignore) 已列明），并保留 `raycast/package-lock.json`（`npm ci` 需要锁文件）。**不要分发编译好的 Helper 二进制**：`swift build` 产物与 CPU 架构绑定（Apple Silicon arm64 / Intel x86_64），必须由对方在本机编译。
3. **构建 Helper**：在仓库根目录的终端执行（命令与下节「Swift Helper」一致）：

   ```sh
   cd helper
   mkdir -p .cache/clang .cache/swiftpm
   CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.cache/clang" swift build --disable-sandbox --cache-path "$PWD/.cache/swiftpm"
   ```

   产物为 `helper/.build/debug/appbind-helper`（绝对路径，后面偏好项与授权都要用到）。命令中的缓存环境变量把 SwiftPM 缓存与模块缓存留在仓库内，是 README 验证过的写法；用户级 Swift 缓存可写时直接 `swift build` 产物位置相同。可选用同样的环境变量运行 `swift test` 自检。
4. **构建 Raycast 扩展**：在 `raycast/` 目录执行：

   ```sh
   cd ../raycast
   npm ci --ignore-scripts --cache .npm-cache
   npm run build
   ```

   `npm ci --ignore-scripts --cache .npm-cache` 按 `package-lock.json` 安装依赖，`--ignore-scripts` 跳过可选 React DevTools 的 Electron 下载器（编译与测试不需要，见「环境限制」）。`npm run build`（即 `build:release`）产出 **release 构建**到 `dist-release/`，只含 Manage Bindings / Create Binding / Background Service 三个正式命令，排除 Helper Status 等调试入口（见 [扩展构建说明](<raycast/README.md>)）；`npm run build:dev` 产出调试构建到 `dist/`（多出的命令仅用于排障）。两者都只写工作区内的构建目录，不安装、不改动 Raycast。
5. **安装 Release 到 Raycast**：保持 Raycast 运行，在 `raycast/` 目录执行 `npm run install:release`（完整说明见上方「本机安装 Release」）。它会再次构建 release、安装到当前这台 Mac，并通知 Raycast 更新命令列表。**不再执行 Import Extension 导入原始源码目录**，否则可能重新注册开发清单中的调试命令。安装后打开 **AppBind 扩展偏好设置**，将 **Absolute Helper Path**（`helperPath`）填为第 3 步产物的绝对路径，例如 `/Users/你/AppBind/helper/.build/debug/appbind-helper`；只填路径，不接受 shell 命令。日常使用不需要 `npm run dev` 保持运行。
6. **授权**：在 **系统设置 → 隐私与安全性** 中把以下两项授权给**同一个 Helper 二进制**（第 5 步填的那个绝对路径；Helper 与扩展都不主动弹授权框，启动缺权限时只保持运行但不执行，见 [SERVICE.md](<helper/SERVICE.md>)；首次操作时若系统弹窗询问，允许即可）：
   - **辅助功能**（Accessibility）：取点、窗口安全校验与真实点击需要；
   - **输入监控**（Input Monitoring）：后台服务监听快捷键需要。
   授权按授权时刻的二进制路径记录：重新编译、清理 `.build` 或移动源码目录导致路径变化时，授权可能失效，需要重新添加并重启服务（授权归属与重编译后的权限持久性尚未实测，见「人工验收（待执行）」第 2 条）。
7. **首次使用**：打开 **AppBind Background Service**，查看权限与运行状态；点击 **启动后台服务** 并确认提示，状态出现「正在运行」「监听与执行就绪」即生效。切回目标 App 按下并松开绑定组合键；窗口身份、遮挡、位置或用户输入变化时会拒绝执行，此时屏幕底部会短暂显示一条 Raycast HUD 风格的提示（毛玻璃胶囊，约 2.5 秒，不夺焦点），同一原因也会记录到「最近错误」。**停止后台服务**结束监听；不会自动添加登录项。

**更新**：对方拿到新源码后（`git pull` 或解压新 ZIP）：如 Helper 有更新，重新构建 Helper（第 3 步）→ 在 `raycast/` 执行 `npm run install:release` → 若已重新编译 Helper，在 **AppBind Background Service** 中点击 **重启后台服务**。不需要再次 Import Extension。注意：**重载已保存的规则**只刷新配置，不更新运行中的程序；权限异常时按第 6 步重新授权。

**数据说明**：规则保存在 Raycast 为各扩展分配的支持目录中（代码里的 `environment.supportPath/config.json`，见 [storage.ts](<raycast/src/storage.ts>) 与 [service.ts](<raycast/src/service.ts>)）。数据只在本机，**不随源码分发，也不跨机器同步**：新 Mac 导入后是空配置，需要重新创建规则；更新源码不会删除本机已有规则（配置与源码目录分离）。

> 面向普通用户的**零命令行安装**（以及自动更新）只能走 Raycast Store：按 [Raycast 官方发布文档](https://developers.raycast.com/basics/publish-an-extension) 提交审核，通过后用户即可在商店搜索安装。发布前需核验清单中的作者与许可证等元数据（[raycast/README.md](<raycast/README.md>)「Distribution boundary」）。手动安装仅用于未上架阶段或少量已知机器。

> 本项目尚未实机执行过导入、授权、启动的全流程验收（见「人工验收（待执行）」与「自动验证记录」）；上文中 Import Extension 的构建行为、授权弹窗等系统细节以实际表现为准，报错时按提示处理。

## Swift Helper

在工作区根目录执行：

```sh
cd helper
mkdir -p .cache/clang .cache/swiftpm
CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.cache/clang" swift build --disable-sandbox --cache-path "$PWD/.cache/swiftpm"
CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.cache/clang" swift test --disable-sandbox --cache-path "$PWD/.cache/swiftpm"
printf '%s\n' '{"protocolVersion":1,"command":"status"}' | .build/debug/appbind-helper
printf '%s\n' '{"protocolVersion":1,"command":"inspect"}' | .build/debug/appbind-helper
```

status 不提示授权，只报告权限和禁用的执行能力。inspect 查询前台 App 的聚焦 AX 窗口；缺少权限时结构化返回 PERMISSION_DENIED，不自行弹授权框。Helper 不输出窗口标题。

从根目录生成结构化 dry-run 请求（只有诊断、没有点击）：

```sh
node -e 'const fs=require("node:fs"); console.log(JSON.stringify({protocolVersion:1,command:"dry-run",config:JSON.parse(fs.readFileSync("examples/config.v1.json","utf8")),bindingId:"toggle-sidebar"}))' | helper/.build/debug/appbind-helper
```

示例使用占位 Bundle ID，通常返回 APP_MISMATCH 或权限错误；这是预期的安全拒绝，不是成功命中。CLI 使用 stdin JSON，不接受任意 shell 内容。未知命令、未知字段、未知版本、坏配置与窗口外/屏幕外坐标均拒绝。

旧 stdin execute 入口固定返回 SAFETY_NOT_IMPLEMENTED（前置请求或配置错误优先返回），不会调用发鼠标事件的 API。授予权限不会自动开启服务；只有显式 service-start 的后台服务路径可以执行规则。

## 后台服务

1. 先创建并保存规则，核对目标 App、快捷键和点位。保存时明确显示是否已加载到服务。
2. 打开 **AppBind Background Service**，查看辅助功能和输入监控权限；自行在系统设置中授予当前 Helper 所需权限。
3. 点击 **启动后台服务**并确认真实点击提示。查看「正在运行」「监听与执行就绪」状态。
4. 切回目标 App，按下并松开绑定组合键；窗口身份、遮挡、位置或用户输入发生变化时会拒绝执行，此时屏幕底部会短暂显示一条 Raycast HUD 风格的提示（毛玻璃胶囊、左侧图标方块、非激活、不接收鼠标），同一原因也会写入最近错误，供事后在面板里查看。
5. 使用 **停止后台服务**结束监听。不会自动添加登录项。重新编译 Helper 后建议先停止再启动，并核验权限。

保存、启停规则和删除规则只重载已经运行的服务。配置保存成功但重载失败会明确告警，不虚报生效。启用标记只是规则状态，不代表服务已启动。服务使用配置原始字节 SHA-256 与保存结果对照。

安全边界与 CLI 控制协议见 [后台服务说明](<docs/background-service.md>)。原有 `Helper Status` 里的 stdin status 描述的是一次性诊断入口，不代表后台服务状态；后台状态请使用新服务页面。

## Raycast 扩展

在扩展目录运行：

```sh
cd raycast
npm ci --ignore-scripts --cache .npm-cache
npm run typecheck
npm test
npm run build
# 下列命令由用户主动执行，将 release 安装到本机 Raycast：
npm run install:release
# 可选：开发时改用以下命令，保留调试入口并持续监听源码：
# npm run dev
```

`npm run build` 使用隔离的 release 构建流程，只生成工作区内的产物；`npm run install:release` 额外写入本机 Raycast 扩展目录并发送命令注册通知。依赖锁定：`@raycast/api 1.104.5`、`React 19.0.0`、`TypeScript 5.9.3`，已按实际安装类型核验 UI API；开发依赖和锁文件位于 [扩展清单](<raycast/package.json>) 与 [依赖锁](<raycast/package-lock.json>)。清单作者/许可证是本地脚手架元数据，公开发布前须由用户确认真实作者、许可和签名分发方案。

开发前在 Raycast 扩展偏好设置填写本工作区编译产物的**绝对路径**作为 Helper 路径。Raycast 客户端使用无 shell 的子进程 + stdin JSON，超时/过大输出/坏协议都按错误处理。扩展的具体入口、依赖版本和构建结果见下方验证记录。

### 录制快捷键（record-shortcut）

创建/编辑表单点击“**设置快捷键**”或按 **⌘⇧R**，进入同一个 Raycast 设置页：搜索为空时直接按组合键录制候选；也可输入 `cmd k`、`ctrl alt k`、`⌘K` 或 `k` 筛选组合，选择后 **Enter** 回填，**Esc** 返回不修改。输入文本期间暂停捕获；清空搜索恢复录制。仅 Shift+字母可能与大写输入冲突，建议小写输入，或先输入空格进入手动模式。已实测 `Cmd+K / Cmd+W` 被 Raycast 抢占，请手动搜索 `cmd k / cmd w`，不宣称可拦截全部组合。

操作菜单保留“**使用原生录制窗口…**”备用：支持实时预览、重录、Enter/按钮确认、Esc/按钮取消。两种录制及手动选择均在确认时检查同 App 的冲突（含禁用项，排除正在编辑的自身）；冲突保留原值，停留设置页继续选择。回填不自动保存，最后按 **⌘S** 保存规则，并再次校验最新配置。

- 仅支持 **A–Z / 0–9 + 至少一个 Control / Option / Shift / Command**，与现有配置格式一致。
- Esc、超时或离开录制窗口取消，原快捷键不变；无效按键不会写入表单。
- 只在显式打开的录制窗口内接收键盘事件，不启用全局监听、不请求辅助功能权限、不注册快捷键、不执行绑定。macOS 保留快捷键可能被系统优先处理。
- 实际按键接收、输入法/键盘布局以及 Raycast 回填仍需人工验收。

### 从窗口取点（capture）

创建/编辑绑定时，操作菜单的“**从窗口取点…**”会关闭 Raycast 面板并显示 Helper 遮罩：目标窗口区域留亮描边、其余屏幕变暗，准星与实时锚点/偏移读数跟随指针；**点击 / Enter 确认 · Esc 取消 · 方向键微调（Shift = 10）**，120 秒无操作自动取消。确认后锚点与偏移自动回填表单，仍由你显式保存。

- 取点**不向目标应用发送点击、不移动真实光标、不激活其他应用**；左键点击遮罩在松开时确认当前准星位置（含方向键微调），与 Enter 共用确认逻辑；按下和松开均由遮罩接收，不穿透到下面的按钮。
- 前置失败关闭：Helper 无辅助功能权限返回 PERMISSION_DENIED（不弹授权框）、目标 App 未运行返回 APP_NOT_RUNNING、取点在窗口/屏幕外或偏移超界返回 UNSAFE_TARGET；取消/失败不写回表单。
- 确认瞬间重读目标窗口 AX 几何；取点身份来自表单（自动获取或手动填写），从不接受客户端提供的窗口几何。
- 遮罩键盘交互、真实权限下的焦点交接与多屏显示属于人工验收范围。

创建规则时通过 Raycast `getFrontmostApplication()` 自动获取激活应用的 Bundle ID（参考 window-panel 的前台应用查询方式），排除 Raycast 自身。先激活目标 App，再打开 Create Binding；也可通过操作菜单“从当前激活应用获取 App ID”重新获取。编辑规则保留原有 App ID，手动输入不会被尚未完成的自动查询覆盖；获取失败时显示错误并允许手动填写。不回退猜测其他应用，也不将此 App ID 视作已验证的窗口身份。新增 3 项获取逻辑单测通过，Raycast 测试累计 11/11；实际焦点行为待人工确认。规则管理仍支持手工填写 Bundle ID、锚点和偏移。快捷键字段只是保存未来服务配置，不会注册热键。配置位于 Raycast `environment.supportPath` 下，单条编辑使用锁保护的读改写和原子替换；不要同时手工修改配置。坏文件显示错误，不静默清空。进程崩溃遗留锁需先确认没有运行中的写入，再手动排障；不会自动抢锁。

Raycast 面板可能自身成为前台 App，dry-run 应安全拒绝该目标；当前不捕获进入面板前的窗口，也不靠固定延迟猜焦点。需要有效前台诊断时从外部受控入口调用 CLI，并由用户核对当前前台窗口。

**Raycast `Action.shortcut` 是面板内操作快捷键，不是全局应用作用域热键。** 为命令设置 Raycast 全局快捷键会占用非目标 App 的同一键，不能满足“未匹配 App 保留按键”。Background Refresh 也不是守护进程。

## 安全边界与未实现项

除规则管理、只读诊断和取点外，新增显式后台服务、配置重载和受保护的点击路径。执行要求窗口身份、AX命中及CG遮挡信息可验证；缺失属性直接拒绝，兼容性不保证。跨阶段重验不能把 macOS 窗口系统变成原子事务，仍需按后台服务说明进行真实环境验收。未实现登录启动和任意应用兼容保证。

坐标使用逻辑桌面空间、X 右 Y 下，不乘 backingScaleFactor。负坐标有纯逻辑支持，但真实多屏混合缩放仍待人工核验。不要通过删除安全检查解决被拒绝的点击。

不承诺所有应用兼容，不保证按钮语义；布局变化后同一坐标可能不是同一按钮。当前版本不收集窗口标题、键入文本或截图。

## 人工验收（待执行）

1. Raycast 本地导入：创建、编辑、启停、删除规则，重开命令确认持久化；同 App 相同热键拒绝，不同 App 可复用。
2. 根据用户自愿授权，对实际 Helper 二进制路径授予 Accessibility，再运行 inspect；核对 Bundle ID、PID 与几何。授权归属与重编译后权限持久性需要实测。
3. 原生/Electron App：无窗口、最小化、模态、前台切换、Raycast 面板焦点都不得被解释为安全可点击。
4. 主屏/左侧和上方副屏、混合缩放、跨屏窗口：对照 dry-run 点和窗口逻辑坐标，检查五锚点及半开边界。
5. 取点遮罩：目标窗口描边与变暗、准星/读数跟随、Enter/Esc/方向键微调、Raycast 面板关闭后的焦点交接、取点结果回填与保存。
5. 权限撤回、Helper 路径缺失、协议版本不匹配、损坏配置、锁忙：显示准确错误，不覆盖坏配置、不点击、不抢鼠标。
6. 后台服务只由用户显式启动，先在无副作用测试窗口验收；完成后停止服务。启动后关闭 Raycast 不等于停止服务；没有安装登录项。
7. 触发被拒绝时的屏幕提示：确认提示是 Raycast HUD 风格的底部胶囊（毛玻璃、左侧图标方块、不夺焦点），鼠标点击穿透、约 2.5 秒消失且不挡住点击目标；在同一提示显示期间再次按热键，应得到同样的真实拒绝原因，而不是被 helper 自己的提示判为「被遮挡」。

## 自动验证记录

根目录的跨组件验证命令（先完成 Swift 构建与 npm 依赖安装）：

```sh
node scripts/smoke-helper.mjs
./raycast/node_modules/.bin/tsx scripts/check-config-parity.ts
```

最终验证结果（2026-09-29，本机环境）：Swift 构建通过；13/13 XCTest 通过；Raycast 类型检查通过、8/8 单元测试通过、官方 CLI 本地构建通过；9/9 CLI smoke 与 25/25 跨语言配置测试通过，以上命令均退出 0。Swift 使用工作区缓存仍有用户级缓存不可写的非致命警告。SwiftPM 的 `--disable-sandbox` 仅关闭包清单的嵌套沙箱，外部工作区文件策略仍有效；本包无第三方 Swift 依赖或构建插件。

对齐测试真实捕获并修复了 Foundation JSONSerialization 去除字符串首 U+FEFF 的差异：Helper 改用保留字符串的 JSONDecoder 模型，再严格校验。中间失败及最终结果详见 [计划验证记录](<docs/plan.md>)。

脚本分别验证结构化响应与 execute 固定拒绝、两端配置规则的一致性，全部不发送输入事件。单元测试通过不代表系统权限、Raycast UI 或真实多屏已通过人工验收。

被拒绝触发的屏幕提示（2026-10-10，本机环境）：Swift 构建通过、59/59 XCTest 通过；提示按 Raycast 原生 HUD 风格绘制（`.hudWindow` 毛玻璃胶囊、底部居中、左侧图标方块取自扩展的 `appbind.png`），在无 bundle 的普通进程下经 WindowServer 实测可见（显示期间能在 `CGWindowListCopyWindowInfo` 中看到 365×64 pt、2.5 秒后消失），并把同一视图离屏渲染成 PNG 核对了胶囊形状、图标与排版（含带遮挡窗口名的两行文本）。遮挡拒绝现在会指名压在目标点上的窗口及其 pid/layer/几何，用于区分真遮挡与矩形误判；全过程未发送任何输入事件。真实触发链路（授权后按热键）仍需人工验收，见「人工验收（待执行）」第 7 条。

环境限制：npm 首次正常安装因 react-devtools 的 Electron 安装脚本尝试写用户缓存而被沙箱拒绝，改用 `--ignore-scripts` 只安装编译与测试所需包；React DevTools GUI 尚不可用。官方 Raycast `ray build` 初次使用默认输出目录时尝试写工作区外的用户扩展目录，被沙箱拒绝；最终使用显式工作区内输出目录的 `ray build -e dist -o dist` 完成原生 CLI 构建与类型检查。没有安装/启用扩展，本地构建成功不等同于 Raycast UI 导入验收。未请求扩大权限或另启后台服务。

