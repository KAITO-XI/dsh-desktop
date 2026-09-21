# 从源码拉起 DSH Desktop（本地构建运行手册）

> 适用：本仓库 `D:\deepseek-harness-desktop`（本地补丁栈分支 `local/pi-ai-model-patch`）构建出的桌面应用。
> 相关文档：分支策略 `docs/local-branch-strategy.md`、搜索反代 `docs/web-search-opencode-go.md`、补丁清单 `local-patches.json`。
> 本文所有路径以本机为准（仓库 `D:\deepseek-harness-desktop`，用户 `kaizhuo.xi`，Yarn 4.18.0 缓存 bundle）；换机器时把这三处替换掉即可。

---

## 0. TL;DR

```powershell
# ① 依赖（首次/换机器）
$env:YARN_NPM_REGISTRY_SERVER='https://nexus.uihcloud.cn/repository/npm-group/'
$yarn = "C:\Users\kaizhuo.xi\AppData\Local\node\corepack\v1\yarn\4.18.0\yarn.js"
cd D:\deepseek-harness-desktop
node $yarn install
node $yarn workspace dsh-plugin-desktop run build

# ② Electron 二进制（首次/换机器，最容易漏的一步）
$env:ELECTRON_MIRROR='https://npmmirror.com/mirrors/electron/'
cd D:\deepseek-harness-desktop\dsh-plugin-desktop
node node_modules\electron\install.js

# ③ 启动（先完全退出安装版 DSH Desktop！）
cd D:\deepseek-harness-desktop\dsh-plugin-desktop
node lib\bin.js
```

---

## 1. 前置条件

### 1.1 依赖安装

```powershell
$env:YARN_NPM_REGISTRY_SERVER='https://nexus.uihcloud.cn/repository/npm-group/'
$yarn = "C:\Users\kaizhuo.xi\AppData\Local\node\corepack\v1\yarn\4.18.0\yarn.js"
cd D:\deepseek-harness-desktop
node $yarn install
```

- **不要用 `corepack yarn`**：本机 corepack 会在 `install` 上空转烧 CPU（此前实测 10 分钟无进展、无子进程），必须用 corepack 缓存里已经下载好的 `yarn.js`（路径见上）。
- 公司 Nexus 镜像缺少 yarn 4.x 的元数据，但 tarball 按需代理正常；`yarn.lock` 已锁定全部版本与校验和，所以设 `YARN_NPM_REGISTRY_SERVER` 就够了。
- `.yarnrc.yml` 设了 `enableScripts: false`：**所有依赖的构建脚本都不会自动执行**（这正是下一步要手工补 Electron 的原因）。

### 1.2 Electron 二进制（必做，否则启动失败）

```powershell
$env:ELECTRON_MIRROR='https://npmmirror.com/mirrors/electron/'
cd D:\deepseek-harness-desktop\dsh-plugin-desktop
node node_modules\electron\install.js
# 成功标志：
Test-Path node_modules\electron\dist\electron.exe     # True（约 225 MB）
Get-Content node_modules\electron\path.txt            # electron.exe
```

- 因为 `enableScripts: false`，`yarn install` 只装了 electron 的 npm 包壳，**不会下载二进制**；`node_modules\electron\dist` 缺失时 `lib/bin.js` 会报
  `electron is not available in this installation`。
- 国内直连 electron 官方下载源常失败，务必带 `ELECTRON_MIRROR`。

### 1.3 构建产物

```powershell
cd D:\deepseek-harness-desktop
node $yarn workspace dsh-plugin-desktop run build
```

产物在 `dsh-plugin-desktop\lib`（`main.js` / `bin.js` / `native-ui\**`）。判断是否构建过：

```powershell
Test-Path D:\deepseek-harness-desktop\dsh-plugin-desktop\lib\main.js
```

### 1.4 可以跳过 `prepare:electron-native`

`dev` / `package:dir` 里会跑 `node scripts/prepare-fs-ext.ts`，它用 node-gyp 编译 fs-ext 的 Electron ABI 绑定，需要 MSVC 工具链。**运行应用不需要它**：仓库里只有打包 smoke 测试断言 fs-ext（`packaged-runtime-smoke.js`，且其 Windows 分支不检查该绑定）。所以直接 `node lib\bin.js` 即可，不必走 `dev`。

---

## 2. 启动

### 2.1 常规方式（把源码构建当作日常应用）

**先完全退出安装版 DSH Desktop（含托盘），再执行：**

```powershell
cd D:\deepseek-harness-desktop\dsh-plugin-desktop
node lib\bin.js
```

**为什么必须先退出安装版**：`lib\main.js` 调用 `app.requestSingleInstanceLock()`，而 Electron 的 userData 目录固定为 `%APPDATA%\DSH Desktop`，安装版与源码构建**共用同一个**。安装版持锁时，源码实例会**静默退出**——表现为 `exit 0`、零输出、`DSH_HOME` 目录都不创建，极易误判为"跑不起来"。

这种方式的优点：共用同一个 `~/.dsh`（`DSH_HOME` 默认值），因此 profile、`dsh-wsl-workspace` 等插件、凭据、历史会话与安装版完全一致。

### 2.2 并存方式（开发/对照，安装版可继续开着）

绕开 `bin.js`，直接给 Electron 一个隔离的 userData 目录：

```powershell
$exe  = "D:\deepseek-harness-desktop\dsh-plugin-desktop\node_modules\electron\dist\electron.exe"
$main = "D:\deepseek-harness-desktop\dsh-plugin-desktop\lib\main.js"
& $exe $main --user-data-dir=D:\dsh-ud-dev
```

- 想连 harness home 一起隔离（**会走全新 profile 向导，没有你的插件与凭据**）：
  ```powershell
  $env:DSH_HOME='D:\dsh-home-dev'
  ```
- 两种隔离目录都是临时物，删掉即可。

### 2.3 带重建的 dev 流程

```powershell
cd D:\deepseek-harness-desktop
node $yarn workspace dsh-plugin-desktop run dev
# 等价于：build → prepare:electron-native → node lib/bin.js
# 若 native 准备失败（缺 MSVC），改用 §2.1 的两条命令手动组合
```

### 2.4 可用参数

```powershell
node lib\bin.js --help                 # 用法
node lib\bin.js --version              # 2.0.13
node lib\bin.js --profile <name>       # 指定 profile
node lib\bin.js --export-diagnostics   # 只导出诊断包、不启动 App
```

---

## 3. 确认"跑的确实是源码构建"

```powershell
# 进程可执行文件应指向源码目录下的 electron.exe
Get-CimInstance Win32_Process -Filter "Name='electron.exe'" |
  Select-Object ProcessId, ExecutablePath
```

- 源码构建：路径形如 `D:\deepseek-harness-desktop\dsh-plugin-desktop\node_modules\electron\dist\electron.exe`
- 安装版：进程名是 `DSH Desktop.exe`，路径在 `C:\Program Files\DSH Desktop\...`

**确认 pi-ai 补丁生效**（模型列表里应有 `deepseek-v4.1-flash`）：

```powershell
$f = "D:\deepseek-harness-desktop\dsh-plugin-desktop\node_modules\@earendil-works\pi-ai\dist\providers\data\opencode-go.json"
(Get-Content $f -Raw).Contains('deepseek-v4.1-flash')   # True
```

应用日志在 `%APPDATA%\DSH Desktop\logs\`（`dsh-<日期>.log` / `.error.log`）。

---

## 4. 故障速查

| 症状 | 原因 | 处置 |
|---|---|---|
| `node lib\bin.js` 秒退、exit 0、无任何输出 | 安装版持单实例锁（同一 userData） | 完全退出安装版；或改用 §2.2 的隔离 userData |
| `electron is not available in this installation` | Electron 二进制没下载 | 执行 §1.2 |
| 启动后窗口空白 / 首次向导反复出现 | 用了隔离的 `DSH_HOME`，profile 是空的 | 去掉 `DSH_HOME`，或在该实例里重新配置 profile 与凭据 |
| `corepack yarn ...` 卡住不动 | corepack 在本机有问题 | 用 §1.1 的 `yarn.js` bundle |
| `yarn install` 拉包 401/403/超时 | 直连 npmjs 不稳 | 确保设置了 `YARN_NPM_REGISTRY_SERVER`（Nexus） |
| electron 下载失败/极慢 | 未走镜像 | 设 `ELECTRON_MIRROR='https://npmmirror.com/mirrors/electron/'` |
| `prepare:electron-native` 报 node-gyp / MSVC 错 | 缺 C++ 工具链 | 不影响运行，跳过（§1.4） |
| 构建产物缺失 | 没跑 build | §1.3 |
| 想同时开安装版与源码版 | 单实例锁 + 同 userData | 用 §2.2 的 `--user-data-dir` |

---

## 5. 与本地补丁栈的关系

| 主题 | 位置 | 说明 |
|---|---|---|
| pi-ai 模型条目 | `patches/pi-ai@0.85.1.patch` + `resolutions`（**仓库内**） | `yarn install` 后自动生效；源码构建与安装版一致地提供 `deepseek-v4.1-flash` |
| 搜索反代 | `tools/opencode-go-proxy/proxy.js` + `scripts/setup-opencode-search-proxy.ps1`（**仓库内脚本 + 机器本地部署**） | 让 `web_search` 经 OpenCode Go 工作，详见 `docs/web-search-opencode-go.md`；换机器执行 `scripts/sync-local-patches.ps1` 会自动补上（它会先跑 machineSetup，再报基线状态） |

启动源码构建前，若基线已随新版本升级，先同步补丁栈：

```powershell
cd D:\deepseek-harness-desktop
scripts\sync-local-patches.ps1 -Check     # 看漂移 + 体检机器本地部署
scripts\sync-local-patches.ps1            # 换基线、重放补丁、构建、验证、推 fork/backup
```

---

## 6. 清理

```powershell
# 停掉源码实例（只杀源码目录下的 electron，别误杀安装版的 "DSH Desktop.exe"）
Get-CimInstance Win32_Process -Filter "Name='electron.exe'" |
  Where-Object { $_.ExecutablePath -like 'D:\deepseek-harness-desktop\*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

# 删除隔离目录（如果用过 §2.2）
Remove-Item D:\dsh-ud-dev, D:\dsh-home-dev -Recurse -Force -ErrorAction SilentlyContinue
```
