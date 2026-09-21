# 本地补丁分支策略（Local Patch-Stack Strategy）

> 本文件是本仓库本地分支管理的**唯一权威说明**。任何 agent 在本仓库内工作前必须读取本文件与 `local-patches.json`。
> 英文摘要见根目录 `AGENTS.md` 的 "Local patch branches" 一节。

## 1. 模型：补丁栈（Patch Stack）

- 本仓库是上游 `anywhere-labs/deepseek-harness-desktop` 的本地定制副本。
- **基线永远跟随"已安装的 DSH Desktop 发行版 tag"**（探测路径见 `local-patches.json` 的 `installedAppProbe`），而不是 `main`——只有与正在运行的安装版严格对齐，"补丁后产物与运行版一致"的验证才有意义。
- 本地提交以 **cherry-pick 栈** 的形式叠在基线 tag 之上；升级即"换基线重放"。

## 2. 分支命名

| 分支 | 用途 |
|---|---|
| `local/pi-ai-model-patch` | 主题分支：pi-ai 模型数据补丁（当前唯一补丁，兼作主线） |
| `local/<topic>` | 今后每个独立主题一个分支（如 `local/xyz-tweak`） |
| `local/v<X.Y.Z>-patches` | 集成分支：当主题 ≥ 2 个时引入，按版本聚合各主题分支 |

- 当前只有一个主题，主题分支即主线；主题变多后再引入集成分支，不要提前复杂化。

## 3. 远端与推送纪律

| remote | 指向 | 允许的操作 |
|---|---|---|
| `origin` | `https://github.com/anywhere-labs/deepseek-harness-desktop.git`（上游） | **只 fetch，永不 push** |
| `mirror` | `https://ghfast.top/https://github.com/anywhere-labs/deepseek-harness-desktop.git`（镜像兜底） | 只 fetch |
| `fork` | `https://github.com/KAITO-XI/dsh-desktop-local.git`（私有镜像仓） | push 本地补丁分支 |

- `fork` 是私有独立仓库（非 GitHub fork：上游 org 限制了 OAuth App 的 fork 权限，GCM 的 gho_ token 建不了 fork，但可建普通仓库）。若将来需要真正的 fork 关联，在浏览器手动点一次 Fork 后把远端换过去即可。
- 本地补丁分支**只推 `fork`**。
- 网络注意：GitHub 直连时断时续，fetch/push 失败先重试，再切换 `mirror`（fetch）/ 等待窗口期（push 只能走 `fork` 直连）。
- 提交身份用 `KAITO-XI <KAITO-XI@users.noreply.github.com>`，避免泄漏企业邮箱。

## 4. 升级同步流程（核心闭环）

安装新版 DSH Desktop 后：

```powershell
# 幂等脚本：自动探测安装版 → 换基线 → 重放补丁 → 装依赖 → 构建 → 验证 → 更新清单
scripts/sync-local-patches.ps1           # 实际执行
scripts/sync-local-patches.ps1 -Check    # 只报告漂移，不改动
```

脚本做的事（等价手动步骤）：

1. 读 `local-patches.json` 的 `baseline` 与 `installedAppProbe` 探测到的安装版比较；
2. 不一致则 fetch 对应 tag（`origin` 失败自动走 `mirror`）；
3. `git switch -c local/v<新版本>-patches v<新版本>`；
4. `git rev-list --reverse <旧基线>..<当前分支>` 取全部补丁提交，逐个 cherry-pick；
5. `yarn install`（registry 走公司 Nexus）+ `yarn workspace dsh-plugin-desktop run build`；
6. 按 `local-patches.json` 的 `verify` 规则验证产物（如 pi-ai 数据文件包含 `deepseek-v4.1-flash`）；
7. 更新清单 `baseline`/`branch` 并提交 `chore(local): sync patches onto v<新版本>`；
8. 推送 `fork`。

**冲突处理**：cherry-pick 冲突时人工/agent 解决后 `git cherry-pick --continue`，再从第 5 步继续（脚本可用 `-SkipBuild` 分段）。`yarn.lock` 冲突的默认解法：取新基线版本（`--theirs`）后重跑 `yarn install` 重新生成。

## 5. Agent 自动检测契约

任何 agent 在本仓库内开始工作前，必须：

1. 读 `local-patches.json`：获得基线、补丁清单、验证规则；
2. 探测 `installedAppProbe`：若安装版 ≠ `baseline`，**主动提示用户并建议运行 `scripts/sync-local-patches.ps1`**（先 `-Check`）；
3. 任何新增本地定制，必须：做成独立 commit（一个主题一串提交）、更新 `local-patches.json` 的 `patches` 与 `verify`、必要时更新本文件；
4. 构建产生的脏文件（如 `dsh-plugin-desktop/build/app-icon.ico` 会被重新生成）用 `git restore` 还原，保持工作树干净。

## 6. 当前状态（同步更新于每次 sync）

- 基线：`v2.0.13`
- 分支：`local/pi-ai-model-patch`
- 补丁：`pi-ai-model-patch`（pi-ai 0.85.1 `opencode-go.json` 新增 `deepseek-v4.1-flash` 模型条目，经 `resolutions + patches/` 机制接入）
