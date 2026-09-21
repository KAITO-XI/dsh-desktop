# Web search on OpenCode Go (local reverse proxy)

> 本文说明本仓库本地补丁栈中的第二个主题：**让 DSH 的 `web_search` 工具经由 OpenCode Go 工作**。
> 分支与补丁清单见 `local-patches.json`；分支管理策略见 `docs/local-branch-strategy.md`。

## 1. 问题

DSH 唯一的搜索 provider 是 `@deepseek-ai/dsh-web-search-deepseek`，它走 **Anthropic 兼容 Messages API**
（`POST {baseURL}/messages`，携带原生 `web_search_20250305` 服务端工具），并且**请求头在代码里写死**：

```
x-api-key / authorization / anthropic-version / content-type / accept / user-agent
```

它的设置项只有 `apiKey` / `apiKeyEnv` / `baseURL` / `model` / `apiVersion` / `maxTokens` / `maxUses`，
**没有注入自定义 header 的位置**。而 OpenCode Go 网关要求每个推理请求携带稳定的
`x-opencode-session`，缺失直接 `HTTP 400 MissingSessionID`。

结论：把搜索指向 OpenCode Go，必须在本机补这一层 header —— 即 `~/工作日志/opencode-go-proxy-迁移指南.md`
中描述的「客户端只能配 baseURL、无法注入 header」场景。

## 2. 方案

```
DSH web-search provider ──► http://127.0.0.1:8787/v1/messages ──► opencode-go-proxy ──► https://opencode.ai/zen/go/v1/messages
   (只带 apiKey)                  (注入 x-opencode-session + 自标识 UA)
```

- 代理实现：`tools/opencode-go-proxy/proxy.js`（零依赖单文件，只加两个 header，body/流式原样透传，**不持有密钥**）。
- 部署脚本：`scripts/setup-opencode-search-proxy.ps1`（幂等：部署文件 → 写自启 → 补 settings → 启动 → 验证）。
- DSH 配置（`~/.dsh/settings.yaml`，由脚本写入）：

```yaml
web-search-deepseek:
  apiKeyEnv: OPENCODE_GO_API_KEY      # 复用 DSH 凭据库里已有的 OpenCode Go key
  baseURL: http://127.0.0.1:8787/v1
  model: deepseek-v4.1-flash
```

搜索端点与对话端点（`llm-pi-ai`）相互独立：本方案不改变 DSH 对话走的是 `https://opencode.ai/zen/go/v1`。

## 3. 模型选型（2026-09-21 实测，经代理调 `/v1/messages` + `web_search` 工具）

| 模型 | 结果 |
|---|---|
| `deepseek-v4.1-flash` | ✅ 4/4 触发搜索，每次 10 条来源 —— **采用**（成本也低于 kimi-k3） |
| `kimi-k3` | ✅ 4/4 触发、7–15 条来源（可用，单价更高，未采用） |
| `minimax-m3` | ⚠️ 不稳定：同一 query 有时 10 条来源、有时完全不调工具 |
| `qwen3.8-flash` | ❌ HTTP 200 但模型自称无搜索工具，无 `web_search_tool_result` 块 |
| `minimax-m2.7` | ❌ 只产生客户端 `tool_use`，不是 `server_tool_use` |
| glm-5.3-flash / grok-4.6 / gpt-5.6-luna / omen-alpha / mimo-v2.5 / longcat-2.0 / hy3 / kimi-k2.7-code | ❌ `/messages` 返回 503 `Endpoint is unavailable`（这些模型不走 Anthropic 协议路径） |

**要点**：provider 在响应里找不到 `web_search_tool_result` 块时**直接抛 `WEB_PROVIDER_ERROR`，不做文本兜底**，
所以「能否稳定触发原生搜索」比模型强弱更关键。成本方面，每次搜索都是一次完整模型调用，
`maxUses`（默认 5）与 `maxTokens`（默认 4096）决定单次开销。

## 4. 使用

```powershell
# 首次部署 / 换机器后（幂等，可重复执行）
scripts/setup-opencode-search-proxy.ps1 -Check                 # 只报告差异
scripts/setup-opencode-search-proxy.ps1                        # 部署 + 启动
scripts/setup-opencode-search-proxy.ps1 -VerifySearch          # 再跑一次真实搜索做端到端验证
```

部署物（机器本地，不在仓库里）：

| 路径 | 作用 |
|---|---|
| `~/.dsh/opencode-go-proxy/proxy.js` | 代理本体（由脚本从 `tools/` 复制） |
| `~/.dsh/opencode-go-proxy/start-proxy.vbs` | 隐藏窗口启动器 |
| `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\dsh-opencode-go-proxy.vbs` | 开机自启 |
| `~/.dsh/opencode-go-proxy/proxy.log` | 请求日志（method/path/status/耗时，不含 body 与 Authorization） |
| `~/.dsh/settings.yaml` | `web-search-deepseek` 段 |

## 5. 排障

| 症状 | 处置 |
|---|---|
| 搜索报 `WEB_PROVIDER_CREDENTIAL_MISSING` | 凭据库里没有 `OPENCODE_GO_API_KEY`；在 DSH 的 Models 页写入，或 `-VerifySearch` 报错即为此因 |
| 搜索报 `HTTP 400 ... MissingSessionID` | 请求没走代理：确认 `settings.yaml` 的 `baseURL` 是 `http://127.0.0.1:8787/v1`，且代理在跑（`curl http://127.0.0.1:8787/healthz`） |
| 搜索报 `no web_search_tool_result blocks` | 该模型没触发原生搜索：换 `deepseek-v4.1-flash`（见 §3 选型表） |
| `502 upstream request failed` | 本机到 `opencode.ai` 不通，与代理无关 |
| 端口被占 / 代理未起 | 看 `~/.dsh/opencode-go-proxy/proxy.log` 的 `START-FAILED` 行；重复自启是预期行为 |

## 6. 撤销

```powershell
Stop-Process -Name node            # 或在任务管理器结束监听 8787 的 node 进程
Remove-Item "$env:USERPROFILE\.dsh\opencode-go-proxy" -Recurse -Force
Remove-Item "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\dsh-opencode-go-proxy.vbs" -Force
# 并把 settings.yaml 的 web-search-deepseek.baseURL 改回 https://api.deepseek.com/anthropic/v1（配 DeepSeek 官方 key）
```
